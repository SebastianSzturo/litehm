# Operating LiteHM

How to run LiteHM's worker, control operations, recover from crashes, and
observe progress. Start with the [README](../README.md) for installation.

## Migrations and rollout

Use explicit `up` and `down` methods. Active Record's command recorder cannot
invert a direct `LiteHM.change_table` call from `change`; `down` must invoke
`LiteHM.revert`. Revert submission is asynchronous by default as well, and the
revert reuses the forward plan's policy (for example `archive: :ephemeral` on a
table with outbound foreign keys); pass `policy:` only to override a key.

Because Rails records the migration version when the job is submitted—not when
cutover finishes—use an expand/contract rollout:

1. Deploy code that works with the old schema and submits the LiteHM plan.
2. Monitor the operation until it has cut over.
3. Deploy code that depends on the new schema.

Do not put code that immediately requires the new column or index in the same
deploy that submits it. Do not roll back the migration version while its
operation is still active; pause or abort the operation first.

An explicit id is strongly recommended. Retrying the same id and canonical
intent resumes its stored compiled manifest; changing the intent, table,
adapter, or policy raises `LiteHM::PlanConflict`.

## Worker queue

Run the configured `litehm` queue. A dedicated queue is strongly recommended:
it keeps week-scale copies from competing with latency-sensitive mailers or
request work, gives them an independent concurrency limit, and makes graceful
shutdown time predictable. LiteHM does not depend on Solid Queue and works
with any Active Job adapter that durably redelivers interrupted/failed jobs.

For Solid Queue, a minimal worker entry is:

```yaml
production:
  workers:
    - queues: litehm
      threads: 1
      processes: 1
      polling_interval: 1
```

If the application also runs a wildcard (`"*"`) worker, that worker can claim
`litehm` jobs too. Replace the wildcard with an explicit list or otherwise
exclude `litehm` when queue isolation matters. Keep the process shutdown grace
period longer than one bounded batch.

Graceful stops are redelivered through Active Job Continuation, but not every
backend redelivers a job whose worker died without one: Solid Queue records a
SIGKILLed, OOM-killed, or rebooted worker's job as a failed execution. Schedule
`LiteHM::RecoveryJob` so such an operation cannot stall silently:

```yaml
# config/recurring.yml (Solid Queue)
production:
  litehm_recovery:
    class: LiteHM::RecoveryJob
    queue: litehm
    schedule: every 5 minutes
```

An operation is **stalled** when it still wants worker time (not paused, not
terminal, not parked at a manual cutover gate or a retained archive), no runner
holds the database writer lease, and nothing was committed for
`config.stalled_after` seconds (15 minutes by default). `LiteHM.recover_stalled`
re-enqueues each stall at most once per stall window; duplicate deliveries are
harmless because the writer lease serializes them. The engine marks stalled
operations and offers **Retry**. An enqueue failure also leaves the plan
visible in the engine; pressing Retry safely enqueues it again. The
target-database ledger—not the job payload—remains authoritative for copied
cursors, phase, commands, and errors.

## Lifecycle and operation controls

```ruby
plan = LiteHM.plan(:messages, id: "20260818-message-delivery") do |table|
  table.add_index :sent_at, name: :messages_sent_at
end

LiteHM.submit(plan)               # asynchronous default used by change_table
LiteHM.submit(plan, start: :paused) # register only; nothing runs until resume
LiteHM.status(plan.id)            # observational; never creates control tables
LiteHM.pause(plan.id)             # observed at the next committed safe point
LiteHM.resume(plan.id)            # enqueue/resume the same durable plan
LiteHM.request_abort(plan.id)     # bounded asynchronous abort before cutover
LiteHM.request_cleanup(plan.id)   # asynchronously release retained archive

# Optional manual cutover policy exposes a Cut over button in the engine.
LiteHM.change_table(:messages, id: "manual", policy: { cutover: :manual }) do |table|
  table.add_index :sent_at
end
LiteHM.request_cutover("manual")

# Explicit synchronous escape hatch for consoles, tests, and rehearsals.
receipt = LiteHM.change_table(:messages, id: "inline", execution: :inline) do |table|
  table.add_index :sent_at
end

# A rollback is another captured migration. It preserves writes made after the
# first cutover and never renames a stale archive back over the live table.
LiteHM.revert(receipt)                       # asynchronous
LiteHM.revert(receipt, execution: :inline)   # synchronous escape hatch
```

A lossy forward change makes `revert` raise
`LiteHM::ReverseProjectionRequired`. Supply a deterministic expression for
each value that cannot be reconstructed:

```ruby
LiteHM.revert(receipt) { |table| table.project :removed_column, "NULL" }
```


## Telemetry

LiteHM publishes structured events through Rails 8.1's
[`Rails.event` / `ActiveSupport::EventReporter`](https://api.rubyonrails.org/classes/ActiveSupport/EventReporter.html).
There is no separate subscription API. In a Rails application, the engine logs
normal LiteHM events as JSON through `Rails.logger` by default. Disable that
subscriber with `config.log_events = false` when the application already exports
events; this does not disable event publication or the engine's metrics.

```ruby
# config/initializers/litehm_events.rb
class MigrationEventSubscriber
  def emit(event)
    # Forward to your existing metrics/log pipeline. Subscribers run
    # synchronously: keep this fast and enqueue any network export.
    MyEventExporter.enqueue(event)
  end
end

Rails.event.subscribe(MigrationEventSubscriber.new) do |event|
  event[:name].start_with?("litehm.")
end
```

Normal production events:

| Event | Purpose |
| --- | --- |
| `litehm.progress` | Periodic worker summary, copied rows, sampled dirty count, phase, and execution state |
| `litehm.state_changed` | Observed phase/state changes and reasons for stopping or awaiting cutover |
| `litehm.command` | A committed operator command, including pause/resume |
| `litehm.retry` | Writer contention, cutover/tail budgets, constraint reconciliation, capture repair, or Active Job lease/busy retries |
| `litehm.failed` | Execution failure, with error class and stage |
| `litehm.enqueued` / `litehm.enqueue_failed` | Active Job submission result |
| `litehm.recovered` | A stalled operation was re-enqueued by `LiteHM.recover_stalled` |

Progress is emitted about every five seconds at committed safe points, plus
milestones and observed state changes. Payloads carry `version: 1`, `plan_id`, and,
for worker events, `table` and a new `execution_id` for each runner. Retry payloads
include a stable `reason`, and the attempt/delay when available. They omit exception
messages, SQL, projections, row values, and database paths. Rails' own parameter
filtering still applies. The built-in log subscriber also omits ambient request
context and tags; applications control what their own subscribers export.

For a focused investigation, enable Rails debug event reporting:

```ruby
Rails.event.with_debug { LiteHM.run(plan) }
```

This additionally publishes `litehm.batch` (committed/rolled-back result, duration,
acquisition wait, next row limit, pacing delay), `litehm.throttle_changed`, and
`litehm.checkpoint` (passive checkpoint duration and frame counts). The built-in
log subscriber omits these high-volume events; subscribe through `Rails.event`
to collect them. The scope above applies to synchronous execution; enable debug
reporting in the worker itself when investigating an asynchronous job.

Event subscribers are invoked after SQLite transactions have ended. Subscriber
failures are reported through `Rails.error` without changing migration success,
even with local Rails event error-raising enabled. Events are best-effort
observations and may be lost or repeated across a crash; the operation ledger is
the source of truth for execution and recovery.

The engine shows copy progress and rate, the last and longest writer
transaction, the next batch size, writer acquisition wait, lock retries,
rollbacks, and the last passive checkpoint's pending WAL frames. Copy percentage
and ETA are shown for single integer keys; other key shapes show copied rows only. Its bounded summary is available as `LiteHM.status(id).telemetry`
and stored in the existing progress JSON during an existing fenced transaction.
It is sampled about every five seconds and at stage/milestone boundaries, never
by adding a telemetry-only writer transaction or work to atomic cutover. A sample
excludes the batch currently committing and any batches completed since that
sample. Timestamps make stale observations visible, including while a paused or
blocked worker cannot save a new sample.

Metrics describe the current worker execution, not application request latency or
lifetime totals. Restarting/resuming begins a new execution; durable copied-row
progress remains cumulative. Stage rates include waiting and pacing. Reconciliation
counts row visits, including its removal and installation passes, so they are not
unique migrated rows. Transaction durations include COMMIT, while explicit passive
checkpoint duration is measured separately. Pending WAL frames describe the last
checkpoint result, not current disk usage; an unavailable checkpoint result is
shown as unknown rather than zero.

The dirty-journal count is also a sample. Counts capped at 251 are displayed as
**At least 251**, including old stored plans that did not record the cap explicitly.
This count excludes the separate reconciliation work set and is not a live count
of all pending work.

