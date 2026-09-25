# LiteHM: a generic online schema-change library for SQLite

> Amended after the pre-release safety review: the original foreign-key freeze
> protocol and version/budget claims below are superseded by the current README. New plans
> journal and prune temporary rows instead of freezing parents. SQLite 3.51.3+
> and sqlite3-ruby 2.9.6+ are required. Batch/time/resource checks are not hard
> latency or disk-allocation guarantees. See the [writer-latency rehearsal](./writer-latency-rehearsal.md) for restored-data evidence.
> Adaptive payload batches, pacing, finite copy frontiers, dedicated execution
> connections, and indexed-only FK pruning supersede the earlier fixed-batch
> and general-FK descriptions below; the README describes the current boundary.
> Design status: implemented. The SQLite assumptions in section I remain executable
> compatibility gates. This is the implementation and test contract for the
> `litehm` Ruby gem, not a proposal limited to one application.

## Recommendation

Build **LiteHM**, a SQLite-native Ruby gem inspired by Shopify's Large Hadron
Migrator (LHM), but do not port LHM's MySQL SQL or its direct-mirroring
implementation. The gem should support every ordinary single-table SQLite
change whose direct execution would scan data, build an index, or rebuild a
table. Its normal interface is the familiar one-call
`LiteHM.change_table`, which durably submits a Rails 8.1 Active Job and returns;
planning, durable resume, validation, automatic atomic
cutover, archive retention, abort, cleanup, and migration-based reversion stay
behind that deep module.

LiteHM is a standalone gem with its own gemspec and no dependency on any
particular Rails application. Its core SQLite implementation
is framework-neutral. Ship two adapters from the start: a raw `sqlite3-ruby`
adapter and an Active Record adapter. Both must be tested against real
file-backed SQLite databases; an in-memory fake or mock connection cannot
substitute for SQLite's WAL, locking, crash recovery, schema-cookie, or pragma
behavior. Use the BSD-3-Clause license, matching Shopify LHM.

The most important implementation departure from LHM is the live-write path.
The semantic goal stays the same: copy-trigger races are expected, repeated
work is idempotent, and the latest committed source state wins. Source triggers
coalesce typed `OLD`/`NEW` row identities into a durable dirty set. The runner
folds that set into staged work and rereads current source rows in short write
transactions. An earlier event-journal design was deliberately simplified
after review: SQLite's single writer and current-state convergence need every
changed identity, not historical row images or statement boundaries.
It must not naively replay one row event at a time: SQLite exposes no statement
or transaction boundary to a trigger, and row-wise replay can fail a newly
added unique constraint during an otherwise valid multi-row value swap. It
should also **not** make application transactions maintain the constrained and
fully indexed target. That separation keeps target index cost and new
`CHECK`/`UNIQUE`/`STRICT` failures out of the source write path. Foreign keys
need an additional runtime contract because a shadow child table is still
visible to parent-table DML on other connections.

A large `messages` table is a strong proving ground, not the product boundary. The first canary can be one non-unique index addition on
`messages`; the library's contract and test matrix must nevertheless cover the
full ordinary SQLite change surface before calling it generic.

## Scope: what “all changes that need an LHM” means

SQLite has a small native `ALTER TABLE` surface. It can rename a table, rename a
column, add a column under restrictions, drop a column under restrictions, and,
as of 3.53, set or drop `NOT NULL`. Some of those operations edit only
`sqlite_schema`; others scan or rewrite all rows. SQLite documents its general
12-step table-rebuild procedure for everything else
([ALTER TABLE][sqlite-alter]). The library should classify a desired target
schema by expected work, not by a Rails method name:

| Change class | Examples | Route |
|---|---|---|
| Metadata-only | safe table/column rename; unrestricted `ADD COLUMN`; `DROP NOT NULL` | Native SQLite in a bounded transaction |
| Scan/storage-sized | `CREATE INDEX`; `DROP INDEX`; add/validate `NOT NULL` or `CHECK`; change/rebuild an index; `REINDEX` | Direct only when a rehearsed writer-pause budget allows it, otherwise the online runner |
| Table rebuild | add/drop/rename/reorder/change type, affinity, default, collation, or generated column; change table options; add/drop/change PK, UNIQUE, CHECK, or FK | Online runner |
| Combined | any number of the above on one table | Compile one target and do one online copy |

“Ordinary table” includes rowid and `WITHOUT ROWID` tables, `STRICT` tables,
`AUTOINCREMENT`, composite keys, generated columns, table/column constraints,
and ordinary indexes (unique, partial, expression, collation, and sort order).
It also includes preserving or deliberately replacing dependent triggers and
views. SQLite's table grammar and index grammar establish that surface
([CREATE TABLE][sqlite-create-table], [CREATE INDEX][sqlite-create-index]).

Feature support is allowed to carry explicit runtime preconditions. In
particular, a target child table with a new/changed outbound FK is visible to
parent-key updates/deletes on other connections even before cutover. The
library supports that schema change only when it can enforce a compatible
parent-DML window; otherwise it rejects the online route before mutation. “All”
means every ordinary feature is either executed under a proved protocol or
refused precisely—never that SQLite's connection-local rules are wished away.

The following are explicit non-goals, not accidental gaps:

- virtual tables and their module-specific shadow tables;
- cross-database/`ATTACH` migrations or changes spanning several tables in one
  atomic plan;
- cardinality-changing ETL, filters, joins, aggregation, or arbitrary Ruby
  row callbacks. LHM-shaped `ddl` remains supported when it mutates only the
  scratch/shadow target schema and compiles to an inspectable manifest;
- nondeterministic per-row transforms that cannot be reevaluated identically
  from the current source row;
- automatically proving that old and new application releases are compatible
  with both schemas;
- making writes lock-free. SQLite permits multiple readers but only one writer;
  the goal is bounded writer leases, not concurrent writers
  ([transactions][sqlite-transactions], [isolation][sqlite-isolation]).

An explicit deterministic SQL projection may cast or derive target values, so
type changes and new required columns remain in scope. One source row must map
to one target row. If a desired target constraint rejects live data, the
operation pauses with an actionable data error; it never drops or coerces the
row silently.

That convergence rule constrains conflict policies too. Expected races between
backfill and live capture are not data errors: reconciling the same source
identity repeatedly is an idempotent success, and newer source state wins.
This is the intent behind LHM's primary-key `INSERT IGNORE` and trigger
`REPLACE`. An unrelated target uniqueness conflict is different. A target `UNIQUE` or PK
declared `ON CONFLICT IGNORE` can silently skip a projected row, while
`ON CONFLICT REPLACE` can delete a different projected row. The first release
must reject non-`ABORT` target constraint policies unless the compiler emits and
proves an explicit precheck/statement policy that converts every such conflict
to an error. The runner's own SQL being careful is not sufficient if the table
constraint itself can ignore or replace.

### Capability and refusal boundary

| Source/target feature | Capability rule | Fail-closed result |
|---|---|---|
| All ordinary columns, constraints, indexes, rowid/`WITHOUT ROWID`/`STRICT` table options | Supported when SQLite can compile the target and the projection is deterministic and one-to-one | `InvalidPlan` with the rejected manifest element |
| Explicit IPK, complete `WITHOUT ROWID` PK, or complete `UNIQUE NOT NULL` source locator | Supported, including composite/text/blob keys and key changes | — |
| Bare source rowid | Only with an enforceable operation-wide no-`VACUUM`/no-DDL contract and an unshadowed rowid alias | `UnsupportedObject` by default |
| Source `OR REPLACE` or a source-writing user trigger | Only with `recursive_triggers=ON` on every writer connection for the whole run | `InvalidPlan`/policy refusal |
| Guarded parent writable through `OR REPLACE`/replace conflict policy | Only with `recursive_triggers=ON` on every connection that can write that parent while LiteHM's guard is active | `InvalidPlan`/policy refusal |
| Target PK/UNIQUE `ON CONFLICT IGNORE` or `REPLACE` (and other non-`ABORT` policies) | Only if the compiler proves an explicit conflict-to-error guard | `UnsupportedObject` in the first release |
| Functions/collations in schema or projection | Supported when deterministic implementations are registered identically on compiler, runner, and application connections | `UnsupportedObject` or `SchemaDrift` |
| Existing triggers/views | Supported when the complete dependency graph compiles against the target and passes cutover tests; unsafe self-mutating `BEFORE` triggers are rejected | `UnsupportedObject` before mutation |
| Source has outbound FKs | Preparation follows the parent-DML rules below. A retained renamed source would remain an FK-live child after cutover, so v1 additionally requires `archive: :ephemeral` plus LiteHM-owned parent-key guard triggers (or a proved equivalent) through bounded archive removal | `UnsupportedObject` before mutation when that guard cannot be installed |
| Other tables have inbound FKs to the source | Supported only when the target projection preserves every referenced key's values, affinity, and collation exactly. Content/semantic changes require coordinated child migration and are outside single-table v1 | `UnsupportedObject` before mutation |
| Logical user index names | Supported through a deterministic logical→physical map in both adapters and schema dumps | A caller requiring that exact raw catalog name receives `UnsupportedObject` |
| Virtual table, cross-database, or cardinality-changing transform | Outside the ordinary-table contract | `UnsupportedObject` |

## What current Shopify LHM actually provides

This review used Shopify LHM commit
[`3374b6071d92a404da60d0295c268af5a2720641`][lhm-commit], version 4.5.1.
The maintained fork is MySQL-only, requires Active Record, and still assumes a
single numeric primary key named `id`
([README lines 37–56][lhm-readme-idea]). Its value is the lifecycle and the
operational lessons accumulated around it, not reusable SQLite implementation.

### Architecture and lifecycle

LHM's public interface is deep: `Lhm.change_table` accepts a change block and
hands the work to an `Invoker`; connection setup and cleanup are the only other
top-level concerns ([`lib/lhm.rb`][lhm-api]). Behind it:

| LHM module | Responsibility | SQLite lesson |
|---|---|---|
| `Migrator` | Clone source DDL, record arbitrary DDL and add/change/rename/remove column and index operations, then apply them to the copy | Preserve a target-schema compiler seam, but compile SQLite manifests rather than concatenate MySQL DDL |
| `Migration` / `Intersection` | Determine old-to-new column correspondence, including renames and generated-column exclusions | Keep explicit source-to-target projection as a first-class immutable plan |
| `Entangler` | Create three ordered `AFTER` triggers; `REPLACE` on insert/update and delete by `id` | Transfer the latest-source-state-wins invariant; implement it through journal reconciliation rather than literal `REPLACE` |
| `Chunker` / `ChunkInsert` | Copy numeric-`id` ranges using `INSERT IGNORE`; verify triggers before batches; reduce stride and retry | Transfer idempotent copy/capture races, bounded adaptive batches, verification, and backoff; replace the SQL and key assumptions |
| throttlers | Time-, replica-lag-, and server-load-based pacing with stride backoff | Expose a policy seam driven by writer latency, busy errors, WAL, disk, and backup lag |
| `AtomicSwitcher` / `LockedSwitcher` | Prefer one MySQL multi-table rename; fall back to table locks and two alters | Neither implementation transfers to SQLite |
| `SqlRetry` / ProxySQL helper | Retry selected lock/network errors and prove reconnection stayed on the same writer | Transfer typed retries and fail-closed identity checks; server failover and ProxySQL logic do not apply |
| cleanup | Retain the old table intentionally, then list or remove leftovers explicitly | Retain evidence and distinguish resumable state from proven orphans |

The current `Invoker` order is: validate and create the altered copy, install
triggers, copy chunks, verify the triggers still exist, then switch atomically
or under a lock ([`Invoker#run`][lhm-invoker]). `Migrator` exposes ordinary
column/index operations plus an arbitrary DDL escape hatch
([migrator operations][lhm-migrator]). `Entangler` mirrors delete, update, and
insert with three triggers ([entangler][lhm-entangler]); `Chunker` checks the
capture mechanism before every chunk and adapts the stride
([chunker][lhm-chunker]). LHM deliberately leaves the archive in place after a
run ([README lines 108–110][lhm-readme-archive]).

Recent maintenance is instructive. Version 4.5.1 changed trigger creation order;
4.5 added Rails 8 and generated columns; 4.4 added chunk backoff; 3.4 made
unexpected `INSERT IGNORE` duplicates warn or raise; and 3.3 added a verifier
that aborts if triggers disappear ([changelog][lhm-changelog]). Small details in
change capture and ignored conflicts have repeatedly been correctness issues.
Shopify's duplicate-warning change documents the distinction explicitly:
primary-key duplicates can occur by design when trigger capture wins the race,
whereas a secondary-unique duplicate can silently lose rows and must be surfaced
([PR #100][lhm-duplicate-pr]). LiteHM preserves that semantic distinction even
though it uses neither literal statement for reconciliation.

### Operation and extension surface

LHM supports add/change/rename/remove column, add unique or non-unique index,
remove index, arbitrary target DDL, optional data filters, custom throttlers,
custom verification, and switch-strategy selection. The custom throttler is a
good seam: a caller can change pacing without knowing copy SQL. The arbitrary
DDL and filter hooks are much less safe. LHM itself warns that a copy filter is
spliced into SQL and does not affect trigger behavior
([README lines 259–274][lhm-readme-filter]). A generic SQLite library should
accept an inspectable target manifest and deterministic projection, not an
opaque mutation hook.

### Safety and testing patterns

Practices worth carrying forward are:

- validate the source and leftovers before mutating;
- install capture before copying and re-verify it while copying;
- use bounded, idempotent chunks with adaptive backoff;
- do a short, atomic cutover;
- keep an archive instead of deleting the only forensic/recovery copy;
- retry known transient lock failures but abort on identity drift;
- run integration tests against the actual database engine.

LHM separates unit and integration suites in its
[`Rakefile`][lhm-rakefile]. Its integration tests exercise the operation DSL,
live insert/update/delete capture, duplicates, composite-PK targets, generated
columns, removed triggers, stride backoff, atomic and locked switching, and
threaded lock waits
([migration integration tests][lhm-integration],
[entangler tests][lhm-entangler-tests], [chunker tests][lhm-chunker-tests]). CI
matrices Active Record, Ruby, MySQL, and driver versions
([workflow][lhm-ci]).

That is a good compatibility pattern, but the proposed library should not copy
LHM's mock-heavy unit boundary. The SQLite module's externally observable
contract is small enough to test through `plan`, `run`, and `status` against a
real disposable file. Its internal classes are implementation details.

### What transfers and what does not

| Transfers | Does not transfer |
|---|---|
| Shadow target, change capture, bounded copy, validation, short atomic cutover, archive, explicit cleanup | MySQL `RENAME TABLE` atomic multi-rename or `LOCK TABLES` fallback |
| Column intersection and rename mapping | Single integer `id` chunking |
| Adaptive throttling, retries, trigger verification | Replica lag, binlog, engine algorithm, and ProxySQL mechanics |
| Real-engine integration/version matrix; idempotent copy/capture races and latest-source-state wins | Literal `REPLACE`, literal `INSERT IGNORE`, or treating unrelated duplicate warnings as correctness |
| One deep change interface | MySQL DDL strings and arbitrary filtered-copy behavior |

SQLite `REPLACE` deletes the conflicting row before inserting and can therefore
run foreign-key actions; broad `OR IGNORE` can suppress `NOT NULL`, `CHECK`, and
unique failures. Neither belongs in a correctness protocol
([ON CONFLICT][sqlite-conflict]).

## Adjacent prior art: DBIx::OnlineDDL

[`DBIx::OnlineDDL` 1.1.2][dbix-tarball], released June 2026, now claims SQLite
support. It is useful evidence that the shadow-copy shape can be made to run,
but it is not a suitable foundation or reference contract. Inspection of the
distribution's `lib/DBIx/OnlineDDL.pm`,
`lib/DBIx/OnlineDDL/Helper/SQLite.pm`, and SQLite tests found that it:

- copies with `INSERT OR IGNORE` and mirrors through generic `REPLACE` triggers;
- rejects a source with any pre-existing SQLite trigger based on the incorrect
  assumption that SQLite does not permit multiple triggers per table;
- silently chooses the first column of a composite primary key for chunks and
  requires a PK/unique key shared by source and target;
- disables foreign keys on its connection and swaps with two renames;
- accepts hook-based target DDL;
- has no evident durable checkpoint/resume state; and
- gives SQLite only narrow operation/concurrency/failure coverage. Its tests
  still skip a drop-column case as unsupported even though modern SQLite has a
  native `DROP COLUMN`.

A real SQLite 3.53.2 file probe performed for this note created two `AFTER
INSERT` triggers on one table successfully. It also confirmed that a named
index cannot be duplicated on source and shadow because user index names occupy
a schema-wide namespace. The proposed design treats both facts as contract
tests, not assumptions.

## SQLite and Rails constraints the implementation must hide

### SQLite behavior

- WAL lets readers coexist with a writer, but there is still only one writer.
  A checkpoint can lengthen a commit, and a pinned read snapshot can let WAL
  grow without bound ([WAL][sqlite-wal]).
- A newly created index scans/sorts the table while SQLite owns the database's
  single writer slot; `CREATE INDEX` has no concurrent mode
  ([SQLite 3.53.2 source][sqlite-refill-index]).
- Since 3.53, native `SET NOT NULL` first scans for nulls and then changes
  schema text ([SQLite 3.53.2 `alter.c`][sqlite-set-not-null]). Native does not
  necessarily mean pause-free.
- SQLite recommends `AFTER` triggers because mutation in a `BEFORE` trigger has
  undefined consequences. Triggers are row-level and expose `OLD`/`NEW`
  ([CREATE TRIGGER][sqlite-trigger]).
- `STRICT`, generated columns, composite PKs, nullable ordinary non-integer PK
  quirks, and `WITHOUT ROWID` materially change copying and identity semantics
  ([CREATE TABLE][sqlite-create-table], [STRICT][sqlite-strict],
  [WITHOUT ROWID][sqlite-without-rowid]).
- Foreign-key enforcement is connection-local, cannot be toggled inside a
  transaction, and must be checked explicitly before cutover
  ([foreign-key pragma][sqlite-fk-pragma], [foreign keys][sqlite-foreign-keys]).
- Modern rename behavior rewrites triggers, views, and FK references; the
  documented “rename old first” shortcut is unsafe without carefully controlled
  legacy behavior ([ALTER TABLE][sqlite-alter]).
- User index names are schema-wide. SQLite has no `ALTER INDEX ... RENAME`, and
  editing `sqlite_schema` through `PRAGMA writable_schema` can corrupt a
  database if any SQL is wrong ([index-name check][sqlite-index-name],
  [writable schema][sqlite-writable-schema]).

### Active Record 8.1 today

The stack examined for this design was Active Record 8.1.3.1, sqlite3-ruby
2.9.5, and SQLite 3.53.2. Rails' adapter enables foreign keys, WAL, `synchronous=NORMAL`,
and immediate transactions by default ([adapter defaults][rails-adapter-config]).

Rails sends `remove_column`, `change_column`, `change_column_default`,
`change_column_null`, and `rename_column` through its private rebuild path
([adapter operations][rails-adapter-operations]). That path moves the table to
a temporary table and then copies it back, all in one DDL transaction—two full
`INSERT ... SELECT` copies and one unbounded writer hold
([adapter rebuild][rails-adapter-alter]). It reconstructs columns, indexes,
foreign keys, and checks, but does not inventory arbitrary triggers and views.
Generated columns are excluded from the copied column set.

The Active Record adapter is valuable as a target-schema compiler, not as the
online execution engine. Running its migration DSL against an empty scratch
database lets Rails interpret version-specific type/default/index behavior
without making its private `alter_table` implementation part of LiteHM's runtime.

## Interface design comparison

Three deliberately different interfaces were considered:

| Candidate | Strength | Failure mode |
|---|---|---|
| Exact LHM-shaped `change_table` only | Familiar and minimal | Gives crash resume, inspection, abort, and cleanup nowhere honest to live |
| Lifecycle-only `plan`/`run`/`status` | Operationally explicit and framework-neutral | Makes the common migration more ceremonial than Shopify LHM |
| LHM facade over a durable lifecycle core | Familiar one-call path plus resumability and raw/Active Record adapters | A few advanced operations exist, but ordinary callers never need them |

Select the third design. `LiteHM.change_table` is the normal interface. It
registers the immutable plan and submits the default asynchronous executor;
`execution: :inline` retains the original blocking behavior for rehearsals.
The immutable plan and lifecycle commands remain available for an operator who
wants prepare-only execution, status, abort, cleanup, or deterministic resume.
Both raw SQLite and Active Record compilation normalize to the same manifest;
neither adapter knows about journals, shadow naming, conflict closure, or
cutover mechanics.

## Public interface

The ordinary LHM-shaped path is one call:

```ruby
operation = LiteHM.change_table(
  :messages,
  id: "messages_delivery_lookup",
  connection: ActiveRecord::Base.connection,
  policy: { writer_lease_ms: 10, max_wal_bytes: 2.gigabytes }
) do |table|
  table.change_column :body, :text, null: false
  table.remove_column :legacy_payload
  table.add_index %i[conversation_id timestamp],
    name: :index_messages_on_conversation_and_timestamp
end
```

The call is idempotent by `id`. An explicit id is recommended; when omitted,
both adapters derive one from the table, source-manifest hash, and canonical
intent hash. It creates or reuses the exact immutable plan,
submits or resumes the durable preparation and returns a `Status` after enqueue.
The job automatically performs atomic cutover when ready unless the plan uses
`cutover: :manual`. A Rails migration records submission, not completion, so
applications must use an expand/contract deploy and monitor the engine before
shipping code that requires the target schema.

The same block supports LHM-style raw target DDL:

```ruby
LiteHM.change_table(:messages, id: "messages_body_check") do |table|
  table.ddl "CREATE INDEX messages_body_prefix ON #{table.name} " \
    "(substr(body, 1, 16)) WHERE body IS NOT NULL"
end
```

`table.name` is an opaque, correctly quoted scratch-target identifier. `ddl`
may modify only that target schema. LiteHM executes it on a disposable real
SQLite file, introspects the result, and records normalized schema SQL; source
DML, cardinality-changing filters, nondeterministic SQL, and Ruby row callbacks
are rejected.

Rails usage is intentionally close to LHM but must opt out of Rails' outer
migration transaction so LiteHM can commit bounded turns:

```ruby
class AddMessagesDeliveryLookup < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    LiteHM.change_table(:messages) do |table|
      table.add_index %i[conversation_id timestamp]
    end
  end

  def down
    LiteHM.revert("the-forward-plan-id")
  end
end
```

The Active Record adapter raises `InvalidPlan` before mutation if called inside
an ambient transaction; it cannot safely turn that transaction off after entry.

Advanced lifecycle operations use the same deep module:

```ruby
plan = LiteHM.plan(:messages, id: "messages_delivery_lookup") do |table|
  table.add_index %i[conversation_id timestamp]
end

LiteHM.submit(plan)               # normal asynchronous operation
LiteHM.status(plan.id)            # immutable value object; no side effects
LiteHM.pause(plan.id)             # stop at a committed safe point
LiteHM.resume(plan.id)            # enqueue the same durable plan again
LiteHM.request_abort(plan.id)     # asynchronous bounded abort
LiteHM.request_cleanup(plan.id)   # asynchronous archive removal
LiteHM.run(plan)                  # explicit synchronous escape hatch

# This starts a second online migration from the current schema back to the
# stored source manifest. It never swaps a stale archive back into service.
reverse_operation = LiteHM.revert(receipt)
```

`revert` matches the real LHM/Rails `down` model: it is a new online migration
that captures and preserves writes made after the first cutover. LiteHM derives
the reverse target from the receipt's stored source manifest. It proceeds
automatically only when it can construct the reverse projection. A lossy change
requires an explicit deterministic reverse projection or archive-backed
backfill; if new rows have no representable old value, planning returns
`ReverseProjectionRequired` or reconciliation returns `DataIncompatible`.
There is no rename-back operation and no reverse mirroring window.

The public commands are:

1. `change_table(...) { |target| ... }` — compile, register, and enqueue; this
   is the default interface.
2. `plan(...)`, `submit(...)`, and `run(...)` — optional operational control;
   `run` is the synchronous escape hatch.
3. `status(id)` — report phase, immutable hashes, progress, validation,
   latency/resources, blockers, retry action, and archive watermark/state.
4. `pause`, `resume`, `request_cutover`, `request_abort`, `request_cleanup`,
   and `retry_operation` — durable high-level commands consumed at safe points.
5. `revert(receipt_or_id)` — compile and submit a new migration to the stored
   prior manifest, never swap the archive back.

The lifecycle is durable and monotonic:

```text
planned -> preparing -> ready -> cut_over -> archive_released -> done
    \-----------> aborting -> aborted
```

`ready` is normally internal and short-lived for automatic plans; manual plans
remain there until an operator requests cutover. A cutover attempt is not a durable phase: its transaction either
rolls back to the existing pre-cutover state or commits `cut_over` atomically.

### Interface invariants and ordering

These are part of the public contract:

1. `plan` is observational only. It compiles the target on an empty real
   scratch database and rejects unsupported or ambiguous objects before the
   production file is mutated.
2. A plan id is immutable. The adapter records a canonical caller-intent hash
   from structured DSL operations, exact raw DDL, and projection expressions.
   Reusing an id with different intent raises `PlanConflict`. Reusing identical
   intent resumes from the **stored** compiled manifest without recompiling it
   under a newly deployed Rails/SQLite renderer; the stored manifest is
   authoritative. The current runtime must still pass its recorded capability,
   function/collation, and version fingerprints or return `VersionUnsupported`.
3. At most one **pre-cutover** plan may own a table; table ownership ends in the
   cutover commit, so a later plan or `revert` can start while prior receipted
   archives remain. Archives and heavy artifacts include the plan id in their
   names and preflight whitelists only artifacts backed by valid prior receipts.
   Only one runner may hold the database writer lease at a time, including old
   archive cleanup, and every mutating transaction verifies its current lease
   epoch/fencing token before writing. A table carrying LiteHM parent guard
   triggers may not simultaneously be the source of another pre-cutover plan.
4. The source table remains authoritative until cutover commits. Preparation
   never renames or drops it.
5. Capture installation and its state transition commit together. While the
   capture objects remain intact, no source write after that commit can escape
   the dirty set. Artifact tampering is detected before the next committed runner
   batch and forces a complete rescan/revalidation or abort before `ready`.
6. Every mutating transaction verifies the current lease epoch/fencing token
   after acquiring its SQLite writer transaction and before changing state.
   Folding dirty identities, advancing copy/reconciliation, updating required
   correspondence, and advancing cursors then happen in that same short
   transaction. A killed or superseded runner repeats or aborts safely.
   Correctness never depends on recovering a source statement boundary that
   SQLite triggers do not expose.
7. A duplicate source identity reached by both copy and capture is expected,
   idempotent work, not a constraint error. The current source image wins. A
   conflict with a different source identity is `DataIncompatible`; it is never
   ignored or resolved by deleting that other row.
8. `ready` means initial copy completed; all then-visible deltas converged to
   current source state; exact row, schema, constraint, correspondence, and FK
   validation passed; and the bounded dirty frontier was checked while holding
   `BEGIN IMMEDIATE`.
9. Source writes may continue after `ready`. Automatic cutover obtains a final
   writer lease and revalidates. If the later frontier exceeds the hard hold
   budget, the transaction rolls back, the runner returns to preparation, and
   it retries with backoff until the configured attempt/deadline policy is
   exhausted. Re-running resumes.
10. Cutover is transactionally atomic. On any failure before commit, the source
    remains authoritative. A crash exposes exactly the complete old or complete
    new catalog state, including dependent objects, sequence, and receipt.
    Existing prepared statements must either reprepare successfully on
    `SQLITE_SCHEMA` or surface that typed transient error; version/driver claims
    remain gated on the cross-process statement-cache matrix.
11. For a source without outbound FKs, the archive freezes at the cutover
    commit and is point-in-time evidence plus an optional
    reverse-projection input. A source with outbound FKs cannot promise a frozen
    archive: v1 marks it `archive_released` at cutover, holds the declared
    parent-key DML freeze, drains/drops it in bounded turns, and only then
    returns. The receipt and `status` expose the watermark and archive policy.
12. Before cutover, `abort` is always available, including after schema drift or
    capture loss. It enters durable `aborting`, removes only artifacts owned by
    the immutable plan, and resumes after a crash. After cutover it is forbidden.
13. A normal retained archive is never cleaned automatically. Explicit
    `cleanup` first commits `archive_released`, ending the recovery promise
    before the first row is removed. An outbound-FK source selects the declared
    ephemeral policy at planning time and commits `archive_released` with
    cutover, then drains before returning. Both paths resume after a crash;
    unknown or mismatched objects are never removed by prefix.
14. Connection-scoped pragmas are recorded, changed only on the dedicated
    connection in legal order, and restored in `ensure` paths.
15. Required parent-key freezes default to LiteHM-owned `BEFORE DELETE` and
    key-`UPDATE` guard triggers on affected parent tables, installed and hashed
    transactionally and removed only after the risk window. A caller may supply
    a proved equivalent guard adapter, but an unenforced promise is insufficient.
    Because SQLite can suppress the implicit-delete trigger of `OR REPLACE`,
    `recursive_triggers=ON` is mandatory on every connection that can write a
    guarded parent whenever replace-style writes are possible; otherwise
    planning refuses.
    Separately, an optional pre-cutover hook may inspect backup freshness,
    replica lag, deploy state, or application health and veto an attempt;
    LiteHM requires neither a backup provider nor human approval.

### Errors and retry semantics

Expose a small typed hierarchy with machine-readable details:

- `InvalidPlan` / `UnsupportedObject`: the desired schema, projection, SQLite
  feature, or dependent object cannot be represented safely.
- `PlanConflict` / `OperationConflict`: a reused id differs, another owner is
  active, or artifacts belong to different durable state.
- `SchemaDrift` / `CaptureLost`: source schema or a capture object changed after
  planning. These fail closed and never block `abort`. Forward resume is legal
  only after restoring the exact manifest/capture under a writer lease and
  durably invalidating every copy/validation range: reconciliation and the
  bidirectional source↔target validation restart from zero so escaped updates
  and deletes cannot hide in a formerly clean range.
- `ReverseProjectionRequired`: the stored prior manifest cannot be populated
  from current rows without a caller-supplied deterministic expression/backfill.
- `DataIncompatible`: a target type/constraint/index rejects current source
  state. Resume only after data or plan repair.
- `AbortUnavailable` / `ArchiveReleased`: the requested recovery action crossed
  its documented point of no return.
- `DiskBudgetExceeded`, `WalBudgetExceeded`, `BusyBudgetExceeded`: pause before
  exhausting the configured operational envelope.
- `ValidationFailed`: exact row/schema/FK/integrity comparison failed.
- `CutoverTimeout`: cutover could not acquire and finish within its retry/budget
  policy; no schema mutation remains committed.
- `VersionUnsupported`: SQLite build/version/compile options have not passed the
  relevant protocol matrix.

Transient `SQLITE_BUSY`, a too-large final frontier, and checkpoint pressure
back off and retry from durable state. Drift, lost capture, incompatibility,
full disk, I/O errors, and integrity failures pause for operator action.
`status` says whether retry is automatic, safe after intervention, abort-only,
or forbidden.

### Performance contract

“Online” means bounded interference, not zero interference:

- every ordinary copy/reconciliation/validation write lease targets a configured
  elapsed duration (for example 50–100 ms), adapting row count down on pressure;
- a source write pays for narrow dirty-identity upserts, not target
  constraints and all target indexes;
- WAL readers remain available; the runner avoids a long read transaction;
- pacing observes p50/p95/p99 application writer latency, `SQLITE_BUSY`, WAL and
  checkpoint state, file free space, dirty backlog, and optional
  backup/replication health hooks;
- the target indexes are maintained incrementally by bounded target writes, so
  cutover never performs a full `CREATE INDEX` scan;
- cutover has hard acquisition and hold budgets and rolls back/retries if either
  is exceeded; automatic cutover never means an unbounded writer hold;
- current defaults are a 10 ms ordinary writer feedback target, 256 KiB batch
  payload target, 16 MiB maximum individual row, 25% writer duty cycle with a
  minimum 10 ms pause, 1,000 ms cutover-lock acquisition, 50 ms final hold, and the earlier of 20 cutover attempts or
  five minutes. Each is configurable and versioned in the receipt; exhaustion
  raises `CutoverTimeout` with preparation intact, so an identical rerun resumes;
- required disk is measured from source table/index pages plus target,
  correspondence, dirty/work state, archive, and WAL headroom. A fixed row-count or 2×
  multiplier is not a safe interface;
- cleanup empties a released large archive in bounded batches before dropping
  it. Freed pages are reusable, while file shrinkage requires a separately
  authorized `VACUUM`.

## Hidden implementation

The implementation is a deep module. The following classes and tables are not
public extension points; they can change without changing callers.

### 1. Compile and preflight

`SchemaReader` inventories `sqlite_schema` plus `table_xinfo`, `index_xinfo`,
foreign-key metadata, `sqlite_sequence`, table options, collations, functions,
and compile options. It finds attached objects and other triggers/views whose
SQL refers to the table; `tbl_name` alone is not a dependency graph
([schema table][sqlite-schema-table]).

`TargetCompiler` creates an empty temporary SQLite **file**, installs the
captured schema, applies the adapter's desired changes, and asks SQLite to parse
and introspect the result. This makes SQLite itself the parser and semantic
validator. It avoids regex rewriting and dependence on Rails' private schema
objects. The compiler emits:

- normalized source and target manifests and hashes;
- canonical caller-intent operations/hash plus compiler/runtime fingerprints,
  so an in-flight plan resumes its stored manifest across compatible deploys;
- exact desired SQL for the table, indexes, triggers, and views;
- stored-column projection expressions and rename hints;
- source identity and target locator strategies;
- dependent-object drop/recreate/rewrite order;
- required SQLite features and cutover strategy; and
- a conservative space/time estimate that the operator must replace with a
  rehearsal before a large production run.

Planning runs read-only schema compilation, capability checks, and a
source-schema snapshot. On the first `run`, preflight repeats the source hash,
runs `quick_check`, `foreign_key_check`, disk/WAL checks, and application policy
hooks, then persists the immutable plan and state tables transactionally in the
database being changed. State in another database could commit separately from
copied rows and is therefore not authoritative.

### 2. Choose stable identities

Chunking and reconciliation need a stable, addressable source locator; it need not be a
numeric `id`:

- `INTEGER PRIMARY KEY`: use the aliased rowid, including negative, sparse, and
  very large values;
- `WITHOUT ROWID`: use the complete non-null primary key, including composite
  text/blob keys and declared collations;
- an ordinary rowid table may use a complete non-null unique key;
- a bare, unaliased rowid is only conditionally stable: SQLite may renumber it
  during `VACUUM` without issuing row DML or firing capture triggers. Default to
  refusing it as source identity. An opt-in mode requires an enforceable
  no-`VACUUM`/no-DDL contract for every process for the operation's lifetime,
  plus at least one unshadowed `rowid`, `_rowid_`, or `oid` alias
  ([VACUUM][sqlite-vacuum]);
- refuse when no unconditionally stable locator is addressable and that strict
  operational contract cannot be enforced. This is still much broader than
  LHM's single numeric `id` restriction.

`Correspondence` is a strategy, not automatically a row-for-row sidecar. When
the source identity survives as the target locator, the target key plus the
copy cursor is already the correspondence; only ahead-of-copy exceptions and
tombstones need durable state. A full encoded source-to-target map is reserved
for source key updates, PK changes/removal, and rowid ↔ `WITHOUT ROWID`
transitions. This matters on a table with tens of millions of rows: paying for a
redundant row-for-row map would materially increase disk, WAL, and total migration
time without improving recovery.

An unkeyed rowid target preserves a safe source rowid where one exists. When a
`WITHOUT ROWID` or unique-key source becomes an unkeyed rowid target, a
same-database sidecar with `INTEGER PRIMARY KEY` plus
`UNIQUE(source_identity)` allocates deterministic target rowids. Allocation and
target insert commit in the same transaction, so reconciliation is idempotent
after a crash.

Key encoding must be collision-free and preserve SQLite storage classes,
collations, null behavior, and composite boundaries. Do not concatenate text or
JSON-stringify blobs.

### 3. Install append-only capture

In one short `BEGIN IMMEDIATE` transaction, create:

- the target table with generated/internal names and target indexes under
  temporary physical names;
- a typed dirty-identity set and staged work set containing coalesced `OLD` and
  `NEW` source locators;
- source-to-target correspondence and allocator tables as required; and
- three uniquely named `AFTER INSERT/UPDATE/DELETE` triggers that only upsert
  old/new dirty identities.

“Typed” here means lossless SQLite identity values in non-coercing sidecar
columns—not JSON. Durable cursors use an explicit storage-class codec, so text
that resembles a number and arbitrary blobs survive capture exactly.

The trigger's dirty upsert is in the application's transaction, so a source
rollback or savepoint rollback removes it too. Event order is intentionally
irrelevant: reconciliation rereads current source state under SQLite's single
writer.
Existing user triggers are allowed when the compiler can round-trip them and
        their interaction policy passes preflight. Correctness must not depend on their
creation order: with recursive triggers enabled, nested source writes dirty
their own identities, and final exact validation catches disagreement. Reject
`BEFORE` triggers that mutate/delete the row being changed because SQLite calls
their result undefined. Capture SQL and trigger hashes are verified before every
batch and final transition.

SQLite fires the implicit delete triggers of `INSERT/UPDATE OR REPLACE` only
when `recursive_triggers` is enabled ([ON CONFLICT][sqlite-conflict]). Otherwise
a replacement with a different source identity can leave the displaced target
row alive with no delete event. Preflight must inspect declared source conflict
policies and application policy. If any writer can issue `OR REPLACE`, or any
source user trigger can modify the source table, require
`PRAGMA recursive_triggers=ON` on **every** writer connection for the entire
operation; because this pragma is connection-local, checking only the runner is
meaningless. Otherwise refuse the plan. Test explicit statement-level replace
separately from a source constraint declared `ON CONFLICT REPLACE`.
Exercise SQLite UPSERT separately: `DO UPDATE` fires the actual update path and
`DO NOTHING` fires no row trigger, which is the behavior Rails bulk upsert APIs
depend on ([UPSERT][sqlite-upsert]).

The parent guard protocol inherits the same replace hazard. With
`recursive_triggers=OFF`, an `INSERT OR REPLACE` on a guarded parent can suppress
the guard's implicit-delete trigger while still executing FK actions against
the shadow/archive child. When replace-style parent writes are possible,
preflight therefore requires `recursive_triggers=ON` on every parent-writing
connection for the full guard window; otherwise it refuses before mutation.

Do not install target user triggers during preparation. Their side effects
belong to post-cutover application writes, not backfill. The dedicated runner
may keep FK enforcement off while a self-referential target is incomplete, but
that does **not** isolate an outbound target FK from other connections. A
parent-table `DELETE` or key `UPDATE` executed with `foreign_keys=ON` can still
inspect, restrict, or cascade into the partially populated target child.

Therefore an unchanged outbound FK requires the reconciliation tests to prove
that duplicate parent actions converge. Adding or changing an outbound FK also
requires LiteHM-owned parent-key guard triggers (or a proved equivalent)
forbidding affected updates/deletes for the preparation window; otherwise v1 rejects the plan
before mutation. This is an engine boundary, not something the runner's local
pragma can fix. All target FKs are validated incrementally before `ready` and
at the final dirty frontier before cutover.

The same issue survives cutover in the renamed source archive: its own outbound
`REFERENCES` clauses remain active for every FK-enabled application connection.
A parent `CASCADE`/`SET NULL` would mutate the supposed snapshot, and
`RESTRICT`/`NO ACTION` can block application DML. V1 therefore permits an
outbound-FK source only with `archive: :ephemeral` and verified parent-key guard
triggers from cutover until the FK-live archive is drained and dropped in
bounded turns. The cutover commit records `archive_released`, so no receipt
claims that archive as recovery evidence. If the contract cannot be enforced,
planning refuses before installing capture. A future detached FK-free evidence
copy is a separate feature, not an implicit v1 promise.

Inbound FKs need a different rule. LiteHM captures only the migrated table, not
concurrent child-table writes. The final dirty frontier is therefore sound only
when the projection preserves every referenced parent-key value, affinity, and
collation exactly. V1 refuses any parent-key semantic/content change while an
inbound FK exists; changing the child rows would be a coordinated multi-table
migration. The compiler inventories inbound references and records the proved
preservation in the manifest.

Both hazards were reproduced on a SQLite 3.53.2/sqlite3-ruby 2.9.5
build: deleting a parent cascaded the renamed child archive from
one row to zero, and promoting a parent target whose key changed from `1` to
`101` left the unchanged child SQL referencing the promoted logical name while
`PRAGMA foreign_key_check` reported the child row as invalid.
The same build also confirmed that, with `recursive_triggers=OFF`, `INSERT OR
REPLACE` bypassed a guarded parent's `BEFORE DELETE` trigger and cascaded its
shadow child from one row to zero.

### 4. Reconcile dirty identities and copy ranges

The dirty set is not a transaction log and is never replayed row-event by
row-event. A SQLite row trigger does not reveal which changes came from one
source statement or transaction. Applying historical events individually can
make a newly added unique constraint reject an intermediate state even when
the committed source state is valid—for example, two rows swapping unique
values. The runner therefore converges **sets of dirty identities to current
source state**.

Each reconciliation epoch works as follows:

1. obtain `BEGIN IMMEDIATE`, verify the current lease epoch/fencing token plus
   plan/source/capture/artifact hashes, and atomically fold the current dirty
   identities into a durable staged work set;
2. copy the next stable source-locator range, except identities already owned by
   a newer reconciliation stage;
3. in bounded turns, remove target rows for the epoch's old target locators and
   mark those work items `removed`; this delete phase makes multi-row key/value
   swaps possible without recovering source transaction boundaries;
4. in bounded turns, reread the current source rows for the epoch identities,
   apply the deterministic projection, insert/update the target, and mark work
   items `installed`;
5. if copy hits a target unique constraint, first reconcile the captured work
   set and retry that bounded batch once. If the current source state itself
   still violates the target, surface `DataIncompatible`; never ignore or
   replace it;
6. advance copy/work-stage cursors and any required correspondence in
   the same transaction as each target mutation, then commit, measure writer
   hold/WAL effects, and adapt or yield.

Source writes after the fold remain in the dirty set for the next epoch. The target may be
temporarily incomplete during a delete/install cycle, but it is never
authoritative before cutover and its user triggers are absent. FK enforcement
on runner DML remains off during these cycles; the separate parent-DML contract
above still applies. A killed runner resumes the durable per-item stage.

For an identity-preserving plan, the target key and copy cursor prevent an
older backfill row from overwriting a newer reconciled image; only exception
identities/tombstones are stored. A full correspondence map makes the same
decision when source and target locators differ.

Indexes are created on an empty target and filled as target rows arrive. This
costs more total incremental work than SQLite's optimized bulk index builder,
but converts one unbounded write statement into bounded writer leases. A direct
index route remains available when restored-copy measurement proves its single
pause fits policy.

### 5. Validate without pinning WAL

Never validate through one hours-long read transaction. It would pin a WAL
snapshot and could prevent checkpoints.

Instead, `Validator` compares bounded locator ranges exactly—storage class and
value after projection, correspondence in both directions, row presence, and
target constraint behavior—while capture continuously records changed old/new
identities in the dirty table. Completed clean ranges may become dirty again;
the dirty set is the truth.

To mark `ready`, first reconcile until the later journal/dirty frontier is below
the configured final-hold budget. Then acquire `BEGIN IMMEDIATE`, fold the
visible journal tail, finish its bounded remove/install stages, compare the
remaining dirty identities exactly, verify counts and correspondence, finish
incrementally maintained target FK/constraint checks, recheck every schema and
capture hash, and persist `ready` before commit. If the tail is larger than the
budget, release the writer lease and do another ordinary reconciliation epoch;
do not stretch the final transaction. No writer can slip between the final
dirty check and the ready state. Subsequent source writes enter the durable
dirty frontier and are folded by the automatic or operator-requested cutover.

Hashing can prioritize diagnosis but never substitutes for an exact comparison
at the dirty-key boundary. Custom SQLite collations/functions used by schema or
projection must be registered on every compiler/runner connection and included
in the plan identity.

### 6. Cut over

Cutover is the automatic final transition of `change_table`/`run` after
`ready`. The same immutable-plan, artifact, and validation checks authorize it;
there is no separate human token:

1. capture connection-scoped pragma values; set `foreign_keys=OFF` before the
   transaction and the rehearsed `legacy_alter_table` behavior;
2. acquire `BEGIN IMMEDIATE` within the hard timeout;
3. verify plan identity, hashes, ownership, and capture; finish the final bounded reconciliation
   epoch and exact-check its dirty identities. If it exceeds the hold budget,
   roll back, release the writer lease, return to preparation, and retry with
   backoff within the operation policy;
4. remove capture triggers and temporarily remove/rewrite dependent objects;
5. execute the version-gated table switch, transfer sequence state, activate
   the target physical-name map, and recreate the exact target trigger/view
   graph;
6. run manifest equality, schema reparsing, representative prepared-statement
   probes, and bounded FK/constraint checks for final dirty identities;
7. persist `cut_over` and the receipt, or `archive_released` for a required
   ephemeral archive, and commit; restore pragmas even on failure. The
   ephemeral path retains its parent-DML freeze and drains the archive in
   bounded transactions before `change_table` returns.

SQLite's documented generalized rebuild order—drop the old table, rename the
target, and recreate dependent objects—is the semantic reference oracle, but a
multi-gigabyte `DROP TABLE` is not an online cutover. Production online mode
therefore requires the two-rename archive switch under controlled legacy rename
behavior, with foreign keys disabled before `BEGIN`, capture/user triggers
handled inside the transaction, and the complete dependent-object graph
reparsed before commit. SQLite explicitly warns that rename-old-first is unsafe
under ordinary modern rename semantics. If the exact SQLite version/FK/object/
crash matrix has not proved this protocol, `plan` returns
`VersionUnsupported`; it must not silently fall back to a huge drop while
claiming bounded cutover ([ALTER TABLE steps 1–12 and warning][sqlite-alter]).

The archive is forensic evidence and an optional input to a reverse projection,
not instant rollback after new writes reach the target. `revert` starts a new
ordinary LiteHM migration from the live target to the stored old manifest so
post-cutover writes are captured. Renaming the archive back is never offered.

`AUTOINCREMENT` needs special handling. Explicit row copies advance the target
only to its largest extant id, while the source's `sqlite_sequence` may be
higher after deleting high ids. Cutover carries forward the maximum promised
sequence so ids are never reused.

Do not run a whole-database `foreign_key_check`, `quick_check`, or
`integrity_check` while holding the cutover writer lease: on a large file the
check itself would become the outage. Full logical/FK validation is incremental
before `ready`; cutover rechecks only final dirty identities and the changed
schema graph. Full pragmas remain valuable before a rehearsal and after commit
as read-only operational evidence, and every crash/fuzz test runs them, but they
are not hidden inside the bounded production cutover.

### 7. Make logical and physical index names explicit

Source and target cannot simultaneously own the same user index name, and
SQLite has no supported index rename. V1 must not put `writable_schema` on the
data-safety path merely to make catalog names prettier. It uses deterministic
target physical names derived from `(table, logical name, plan id)` and persists
the live logical→physical map in a small permanent `litehm_index_names` control
table as well as the immutable manifest and cutover receipt. `cleanup` never
drops that live map.

That mapping is a real adapter contract, not an invisible compromise:

- `status` and the raw adapter expose both names;
- the Active Record adapter resolves `index_exists?`, `remove_index name:`, and
  schema dumps through the logical map;
- schema dumps emit logical names. Loading a dump through the installed LiteHM
  Active Record adapter creates generation-zero physical names and seeds the
  map, so normalized logical dump→load→dump is stable even though raw physical
  names need not match the source file;
- the Active Record/raw LiteHM adapters reject or resolve out-of-band DDL by
  logical name for managed tables. A foreign SQLite connection cannot be
  intercepted and will see only the physical catalog name; this is a documented
  raw-SQL constraint, not an enforceable global lint; and
- a caller that requires the raw catalog to contain an exact preexisting name
  receives `UnsupportedObject` before mutation.

A disposable SQLite 3.53.2 probe found that a narrow transactional
`writable_schema` rename can survive reload, `INDEXED BY`, writes, and
`integrity_check`, but SQLite warns that malformed schema edits can corrupt the
database ([writable schema][sqlite-writable-schema]). Keep exact physical-name
rewriting as post-v1 research only. It may ship later solely as a sealed,
version-gated opt-in after statement-level crash injection and post-reopen
integrity fuzzing across every supported release; it is not required for the
safe generic core. Autoindexes created by table constraints follow the table
rename and are tested separately.

### 8. Resume and clean up

Every phase is derived from durable state plus artifact hashes after reopening
the database:

- setup not committed: no owned artifacts exist;
- capturing/copying/validating: verify and resume exact cursors; after repaired
  `CaptureLost`/`SchemaDrift`, first commit a new full-rescan epoch and reset all
  reconciliation/validation cursors before any range may become clean again;
- ready with later deltas: remain ready-to-attempt, then run the final bounded
  reconciliation epoch at cutover;
- cutover transaction rolled back: source remains logical and preparation is
  resumable;
- cutover committed but process died before returning: database state proves
  success;
- abort requested before cutover: enter `aborting`, remove plan-owned capture
  first, then resume bounded target/journal/state cleanup until `aborted`;
- cleanup requested after cutover: commit `archive_released` before deleting the
  first archive row, then resume bounded emptying until `done`.

The cutover receipt records timestamp, converged capture state, plan-qualified
archive name, source/target manifests, projection, and identity correspondence strategy.
`status` reports whether the archive is intact, released, partially drained, or
gone. Never offer blanket prefix cleanup. List owned artifacts, archive age,
logical/physical bytes, and recovery action. Delete only objects whose durable
plan ownership matches; drift can block forward progress but cannot strand the
plan's own capture triggers after an explicit pre-cutover `abort`.

`done` removes heavy per-run journals, worksets, targets, and archives, not the
small permanent control plane. Receipts, historical manifests needed by
`revert`, and the current live logical→physical index-name map remain durable.
Multiple prior receipts/archives may coexist because ownership and names are
plan-qualified; they do not retain exclusive ownership of the logical table.

## Adapter strategy

The adapter seam should be narrow:

```ruby
module LiteHM
  module Adapter
    # Read database identity/capabilities and compile the caller's target on a
    # scratch file. Return a normalized Manifest; do not execute online phases.
    def compile(plan_request) = raise NotImplementedError

    # Open a dedicated raw SQLite connection with required functions/collations.
    def connect(database_identity) = raise NotImplementedError
  end
end
```

Everything after compilation operates on quoted SQLite SQL and normalized
manifests. No engine class calls Active Record migration internals.

### Raw SQLite adapter

- uses sqlite3-ruby's database path/handle information and opens dedicated
  file-backed connections;
- accepts exact target table/index/trigger/view SQL plus explicit projection or
  rename hints only where inference is ambiguous;
- registers caller-provided functions and collations on compiler and runner
  connections;
- is the reference adapter and keeps the core independently useful.

### Active Record adapter

- inventories through raw SQLite plus Rails metadata where useful;
- creates a real empty scratch app database, installs source schema, and applies
  the caller's familiar table-change block there;
- records rename/projection hints while Rails executes, then normalizes SQLite's
  resulting schema rather than retaining Rails schema objects;
- supports Rails migration vocabulary for columns, indexes, FKs, checks,
  generated columns, and table options; operations Rails does not expose can be
  supplied as target schema SQL through the adapter, still compiled on scratch;
- opens a dedicated raw connection for the online run, so pool checkout,
  transaction nesting, and Rails' two-copy `alter_table` implementation cannot
  leak into the engine;
- rejects an ambient Active Record transaction before mutation and documents
  `disable_ddl_transaction!` for Rails migrations;
- installs through a Railtie (or explicit `LiteHM::ActiveRecord.install!`) so
  `index_exists?`, name-based removal, and schema dump/load resolve and seed the
  permanent logical→physical map consistently;
- lets a Rails migration call `LiteHM.change_table` directly; the migration
  returns after durable registration and Active Job enqueue. A mountable,
  fail-closed engine exposes status and lifecycle commands without accepting
  arbitrary SQL or Ruby.

Two real adapters make the seam honest. Test doubles would encourage an
interface shaped around imagined SQLite behavior; local file databases and tiny
Rails test apps are fast, deterministic, and substitutable.

## Gem and repository shape

Create a self-contained Ruby gem:

```text
litehm/
├── litehm.gemspec
├── Gemfile
├── Rakefile
├── LICENSE
├── README.md
├── app/                       # isolated monitoring/control engine
├── config/routes.rb
├── lib/
│   ├── litehm.rb
│   └── litehm/             # public values plus private implementation
├── test/
│   ├── unit/               # pure manifest/value behavior only
│   ├── integration/        # real file-backed SQLite lifecycle tests
│   ├── concurrency/        # multi-process deterministic schedules
│   ├── fault/              # real-engine statement/commit kill points
│   ├── dummy/              # fresh Rails 8.1 engine/job application
│   └── fixtures/rails_app/ # migration compatibility application
└── gemfiles/                    # Active Record/sqlite3 compatibility matrix
```

Use Minitest and Rake. The shipped runtime requires Rails 8.1 and `sqlite3`;
Active Job Continuations are the graceful deployment handoff layer while the
target-database ledger remains authoritative. The fixture Rails application is not
a mock or dummy adapter: tests generate a fresh app database, run actual Rails
migrations containing `LiteHM.change_table`, drive concurrent independent Rails
and raw-SQL writers, kill/restart the migration process, and compare the result
with Rails' quiescent schema outcome.

Unsupported operations fail before mutation, and no feature is documented as
supported until its real-engine, concurrency, and crash matrices pass.

## Thorough test plan

The test oracle is a quiescent result made by SQLite's documented rebuild
procedure. For each generated source schema, source dataset, target manifest,
and source DML trace, compare the online result with that reference: normalized
schema graph, exact projected row multiset and storage classes, sequence state,
FK/check/integrity results, and representative query behavior.

All behavioral tests use real temporary **files** in WAL mode with at least
three independent connections or worker processes. In-memory SQLite is allowed
only for pure formatting tests, never lifecycle correctness. Internal classes
are not mocked; fault injection wraps actual SQLite statement boundaries.
`bundle exec rake` runs every deterministic correctness, lifecycle, fault, and
concurrency test by default. Only the cross-version/platform matrix, randomized
soak duration, and restored multi-gigabyte benchmark are split into longer CI
jobs. There is no opt-in "concurrency suite" whose omission can produce a green
correctness build.

### A. Public contract and state machine

- pure/idempotent `plan`; immutable ids; source drift and artifact ownership;
- resume identical canonical intent from the stored manifest after a compatible
  Rails/SQLite upgrade; reject changed intent under the same id; refuse an
  incompatible runtime without abandoning or recompiling the stored plan;
- every legal phase order and every illegal transition;
- repeat every `run` call before, during, and after its target phase;
- kill after every durable statement/commit boundary, reopen in a new process,
  and prove resume or rollback from database state alone;
- concurrent runners, expired/renewed leases, automatic cutover retries, and process
  pause longer than heartbeat;
- abort after every pre-cutover durable boundary, including drift/capture loss;
  kill during abort, reopen, and prove zero plan-owned write-path artifacts;
- drop capture, commit uncaptured writes, restore it, and prove no resume reaches
  `ready` until a full bidirectional reconciliation/validation epoch completes;
- pause a runner beyond lease expiry, let a successor fence it, then prove the
  stale runner cannot commit any batch or cursor update;
- prove cutover's binary crash outcome at every statement: complete old state
  and resumable preparation, or complete new state and a committed receipt;
- for FK-free sources, freeze the archive at its recorded watermark; write after
  cutover and prove it is byte-stable and no public path renames it back. For an
  outbound-FK source, prove `archive_released` commits at cutover, parent-key DML
  stays frozen, bounded removal finishes, and no receipt advertises an archive;
- commit `archive_released` before the first destructive cleanup step; kill at
  every cleanup boundary and resume without reviving the recovery promise;
- run A→B then `revert` B→A: prove automatic reversal for representable changes,
  explicit projection for lossy changes, and `DataIncompatible` without loss;
- pragma restoration and connection loss at every transition.

### B. Complete schema-change matrix

Individually and in combinations:

- add/drop/rename/reorder columns;
- declared type/affinity, default expression, collation, nullability;
- virtual and stored generated columns and dependency chains;
- column/table `CHECK`, `UNIQUE`, PK, and FK additions/removals/changes;
- rowid, `INTEGER PRIMARY KEY`, `AUTOINCREMENT`, `WITHOUT ROWID`, and `STRICT`
  transitions where SQLite permits the target schema;
- create/drop/change unique/non-unique, partial, expression, descending, and
  collated indexes, including duplicate names and quoted identifiers;
- target UNIQUE/PK conflict policies `ABORT`, `FAIL`, `ROLLBACK`, `IGNORE`, and
  `REPLACE`, proving non-ABORT policies either fail preflight or are forced to a
  surfaced error without loss;
- several changes compiled into one target/copy;
- deterministic casts/expressions and every target constraint rejection.

### C. Identity and value matrix

- empty, one-row, dense, sparse, negative, and maximum integer rowids;
- high deleted `AUTOINCREMENT` values and sequence rows absent/present;
- no declared PK under both default-refusal and enforced no-`VACUUM`/no-DDL
  modes; non-integer ordinary PK (including SQLite's nullable-PK quirk);
  composite text/blob PK; custom collation; `WITHOUT ROWID`;
- source identity updates and target PK changes;
- rowid ↔ `WITHOUT ROWID`, including deterministic sidecar allocation;
- user columns shadowing one, two, or all hidden-rowid names;
- all SQLite storage classes in weakly typed columns, NUL text, NaN/infinity
  adapter behavior, large blobs, zero-length values, and composite encodings.

### D. Schema-object graph

- multiple source triggers for every timing/event; nested writes;
  `recursive_triggers` on/off; `RAISE` actions; trigger names that collide with
  generated names;
- statement-level `INSERT/UPDATE OR REPLACE` and constraints declared
  `ON CONFLICT REPLACE`, proving displaced identities are captured only under
  the all-writers recursive-trigger contract;
- `INSERT ... ON CONFLICT DO UPDATE` for same-row and different-row conflict
  targets (including `excluded` expressions), `DO NOTHING`, and Rails
  `insert_all`/`upsert_all`, proving the actually fired insert/update/no-op path
  produces exactly the expected capture;
- views and nested views, including external objects that refer to the table;
- inbound, outbound, self, composite, deferred/immediate FKs and every action;
- parent-table deletes/key updates while an unchanged, added, removed, or
  action-changed FK target is only partially populated; prove the declared
  parent-DML contract or preflight refusal on independent app connections;
- post-cutover parent `DELETE`/key `UPDATE` against a renamed archive for every
  FK action, proving the observed archive mutation/block and the mandatory
  ephemeral-archive contract;
- LiteHM-owned parent guard triggers across independent raw/Rails connections,
  including existing parent triggers, attempted tampering, crash/resume, self-FK
  parents, and removal only after the shadow/archive risk window;
- `INSERT/UPDATE OR REPLACE` and declared replace policies on a guarded parent
  with `recursive_triggers` on/off, plus grandparent→parent cascades, proving the
  guard fires or preflight refuses the writer policy;
- inbound child writes while parent validation is in progress; prove exact
  referenced-key value/affinity/collation preservation succeeds and any
  semantic/content-changing parent projection is refused before capture;
- generated expressions, partial/expression indexes, quoted identifiers,
  registered deterministic functions and collations;
- exact object SQL/name round-trip, prepare/reprepare after schema-cookie change,
  and old/new application connections spanning cutover.

### E. Concurrency and latency

Run bounded-exhaustive small interleavings plus deterministic and randomized
multi-process writers throughout preparation and automatic cutover:

- insert/update/delete, locator/PK changes, multi-row statements, transactions,
  savepoints, rollbacks, nested trigger writes, UPSERT/DO NOTHING, and
  target-unique conflicts;
- newly added unique constraints with two-row and N-row value swaps in one
  source statement/transaction, with reconciliation batch boundaries forced
  between every captured event;
- force deltas ahead of and behind the copy cursor and grow/drain backlogs;
- slow readers that pin WAL, manual and automatic checkpoints, long source
  writers, and cutover acquisition timeout;
- report throughput plus p50/p95/p99/max writer latency, busy rate, runner lease
  duration, journal depth, WAL high-water, checkpoint time, and total write
  amplification against a no-migration baseline;
- for every capture/reconcile/cutover boundary, cross it with every DML class
  and assert writers using the documented busy handler eventually commit or
  receive their own application constraint error in the explored schedule.
  Hardware-sensitive latency percentiles are reported; configured lease/
  acquisition deadlines and final-state equivalence are hard assertions.

### F. Fault and corruption injection

- `SIGKILL`/power-loss simulation after every SQL statement and commit point;
- `SQLITE_BUSY`, `LOCKED`, `FULL`, `IOERR`, `CORRUPT`, out-of-memory where the
  binding can inject it, permission changes, connection close, and disk
  exhaustion with WAL/archive headroom boundaries;
- remove or alter capture triggers, state, target, correspondence, journal,
  index, view, source schema, pragma, or registered collation mid-run;
- cutover failure at every statement, especially archive rename, sequence
  transfer, physical-name-map activation, dependency recreation, checks, and
  commit;
- after every crash: reopen with a fresh process and run schema parse,
  `quick_check`, `integrity_check`, and `foreign_key_check` before resume.

### G. SQLite, binding, Rails, and platform matrix

The initial support contract is Ruby 3.2–3.4, sqlite3-ruby 2.x, Active Record
7.2–8.1, SQLite 3.37 through current, and Linux/macOS. Test the minimum, current,
and every relevant feature boundary:

- reject SQLite older than 3.37; retain 3.25/3.26 rename, 3.31 generated-column,
  and 3.35 drop-column cases as negative/version-routing fixtures; test 3.37
  strict/add-column checks and 3.53 set/drop-not-null behavior directly;
- amalgamation builds with supported compile flags and defensive/trusted-schema
  settings; macOS and Linux filesystems;
- supported sqlite3-ruby releases and Rails versions, including Rails' current
  migration and schema-dump formats;
- WAL and rollback journal if the library claims both. Otherwise reject the
  untested mode explicitly;
- logical/physical-name mapping on every supported SQLite and Rails version.
  Generate quoted/unicode names and schema graphs, crash within cutover, reopen,
  and require exact normalized manifest plus stable dump/load behavior. A
  future opt-in metadata finalizer gets its own stricter fuzz matrix.
- pin a first-class canary to the oldest supported Ruby, Rails, sqlite3-ruby,
  and SQLite releases.

### H. Model-based/property tests

Generate legal ordinary source/target manifests and DML traces. Shrink failures
to a minimal schema, data set, event trace, and kill point. Core properties:

- final target state equals the deterministic projection of final committed
  source state; idempotent at-least-once internal work is allowed;
- a test-only journal accounting oracle separately proves every actual capture
  trigger firing is present and every committed watermark is eventually folded;
- copy/reconciliation order and batch boundaries do not change the final result;
- rerunning any committed batch is a no-op;
- source stays authoritative until one atomic cutover commit;
- the online result equals the quiescent SQLite rebuild oracle;
- no success state has a dirty key, unapplied event, manifest mismatch, or
  failed integrity/FK check.

### I. Release-gating executable spikes

Before documenting the affected capability as supported, run small standalone
probes across every claimed SQLite/sqlite3-ruby version and compile-option set:

- the two-rename cutover with `legacy_alter_table`, `foreign_keys=OFF`, quoted
  names, inbound/outbound/self FKs, views, and triggers; prove exactly which
  `REFERENCES` text rewrites and compare with SQLite's documented rebuild oracle;
- post-rename archive FK liveness for `CASCADE`, `RESTRICT`, `NO ACTION`,
  `SET NULL`, and `SET DEFAULT`;
- a `DELETE` without `WHERE`, proving installed capture triggers disable or
  safely account for SQLite's truncate optimization;
- UPSERT `DO UPDATE`/`DO NOTHING` and `OR REPLACE` trigger firing with
  `recursive_triggers` both on and off, for source capture and for implicit
  deletes/cascades on a guarded parent;
- journal `INTEGER PRIMARY KEY` event ordering under interleaved deferred
  transactions, savepoint rollback, rollback of the maximum event id, and id
  reuse; the proof needs only a total order of committed visible events, not a
  source transaction boundary;
- cross-process prepared-statement behavior at schema-cookie change, including
  sqlite3-ruby/Active Record statement caches and required `SQLITE_SCHEMA`
  reprepare behavior;
- `BEGIN IMMEDIATE` plus lease-epoch fencing in two processes, proving no writer
  enters between final dirty validation and cutover and no expired runner commits;
- multi-row UNIQUE/PK swaps with every event/batch boundary and stale-owner
  conflict-closure expansion;
- the permanent logical→physical index map through two successive migrations,
  cleanup, schema dump/load, revert, and crash at map activation.

A failed spike produces `VersionUnsupported`/`UnsupportedObject` for that exact
feature/version; it never becomes a best-effort branch in the generic runner.

### J. Scale and operations proving ground

Rehearse on a restored copy of your largest tables with realistic writer
traffic, the same SQLite build and pragmas, and any continuous
backup/replication process running. Row count is a poor router: a table with
few rows but large payloads can be larger than one with tens of millions of
small rows. Measure direct `CREATE INDEX` against shadow preparation, dirty
validation, the archive cutover and drop/rename semantic oracle, restart
recovery, WAL checkpoints, disk high-water, backup lag, and bounded archive
cleanup. Verify a recent restore point and restore drill before every
destructive rehearsal.

Run LiteHM on its own configurable `litehm` Active Job queue (and ensure
wildcard workers do not defeat that isolation). `LiteHM.change_table` remains
legal directly inside a Rails migration because it submits rather than running
the multi-hour lifecycle inline. Implementation verification stops at
disposable fixture applications and restored copies; it does not run or deploy
a production migration. Start with a non-unique index as a first canary, then a
reversible column rebuild. Do not infer generic readiness from the canary: all
earlier matrices remain release gates.

## Delivery sequence and gates

1. **Gem skeleton and executable specification:** create the gem, its
   gemspec, BSD-3-Clause license, Minitest/Rake harness, quiescent manifest
   oracle, public interface tests, and durable state-machine tests.
2. **Capture/copy prototype:** raw adapter, all identity strategies, delta and
   dirty journals, set reconciliation (including unique swaps), conditional
   correspondence, crash resume—no cutover.
3. **Target compiler and Active Record adapter:** complete change matrix against
   scratch real databases; support inspectable LHM-style target `ddl`; prohibit
   source mutation and opaque row callbacks.
4. **Validation and constraints:** exact incremental+dirty validation, target
   incompatibility diagnosis, schema objects, FKs, generated/strict tables.
5. **Cutover spikes:** documented drop/rename semantic oracle, required archive
   switch, sequence transfer, and logical/physical index mapping. Select only
   protocols that pass versioned fault injection; exact raw index names remain
   an explicit refusal rather than a reason to use `writable_schema` in v1.
6. **Recovery and reversal:** unconditional crash-resumable pre-cutover abort,
   immutable receipts/archive watermarks, explicit archive release/cleanup, and
   `revert` as a second online migration with lossless and lossy cases.
7. **Default concurrency and chaos suite:** bounded-exhaustive interleavings,
   property tests, process kills, disk/I/O/busy faults, SQLite/Rails/binding/
   platform matrix, and performance regression suite.
8. **Rails end-to-end and scale verification:** run real migrations and mixed
   Rails/raw writers in `test/fixtures/rails_app`, then rehearse against a restored
   production-scale copy without touching production.
9. **Document and publish when requested:** raw and Rails guides, operational
   runbook, support matrix, recovery tooling, and explicit semantics for every
   rejected object. The gem is a standalone package from the start.

Release “generic” only when all ordinary schema features above either pass or
produce a documented `UnsupportedObject` before mutation. Release “online” only
when a declared hardware/workload envelope meets writer-latency and cutover
budgets; it is not a universal performance promise.

## Tradeoffs and rejected alternatives

| Choice | Benefit | Cost / risk |
|---|---|---|
| Delta journal rather than LHM direct mirror | Small predictable app-write amplification; target constraints/indexes do not normally abort source-row writes | More disk/state; reconciliation lag; target error appears asynchronously; shadow FKs still need a parent-DML contract |
| Target indexes maintained incrementally | No unbounded `CREATE INDEX` at cutover | More total writes and slower copy than SQLite's bulk builder |
| Conditional correspondence strategy | Identity-preserving plans avoid a redundant full sidecar; PK changes and rowid transitions remain possible | More planner/recovery branches; transformed identities still pay for a full map |
| Real scratch compiler | SQLite/Rails interpret their own grammar; avoids regex | Extra temporary file and adapter work; registered functions/collations must be supplied |
| Exact incremental + dirty validation | No hours-long WAL-pinning snapshot; bounded final proof | Dirty set can grow under hot-key workload; readiness may need repeated drains |
| Version-gated archive switch | Avoids a multi-gigabyte drop in cutover and retains forensic evidence | Mandatory SQLite rename/FK/object proof; archive is not instant rollback after new writes |
| Logical→physical index map | Avoids unsupported catalog edits and an index rebuild | Raw index names differ; adapters and schema dumps must honor the mapping |
| LHM facade over lifecycle core | Familiar one-call migration with optional operational control | More commands than LHM, but resume/abort/cleanup/revert have explicit homes |

Rejected approaches:

- porting Shopify LHM SQL or depending on MySQL-oriented internals;
- literal broad `REPLACE`, `INSERT OR IGNORE`, or unrelated constraint-error
  suppression; their intended idempotent-race semantics are preserved;
- replaying trigger events row by row without source statement boundaries;
- direct target mirror triggers for a fully indexed/constrained target;
- chunking only numeric `id`;
- one long validation snapshot or one unbounded copy transaction;
- building missing indexes during cutover;
- editing `sqlite_schema`/`writable_schema` on the v1 correctness path;
- parsing/replacing `CREATE TABLE` with regex;
- copying Rails' private two-copy `alter_table` method;
- mocks as the SQLite dependency seam;
- opaque target-DDL callbacks or filtered/cardinality-changing copy;
- automatic blanket cleanup by name prefix.

## Name and package

The selected name is **LiteHM**: gem `litehm`, Ruby module `LiteHM`, repository
`litehm`. It deliberately echoes LHM while naming the lighter
SQLite engine. At naming time the RubyGems API returned 404 for exact `litehm`,
and GitHub repository-name search returned no exact `litehm` repository. This
is an availability check, not trademark, organization, domain, or
future-availability clearance.

## Bottom line

LiteHM is technically credible if treated as a SQLite concurrency and recovery
system behind an LHM-shaped Ruby interface, not as a Rails DSL wrapper. Shopify
LHM supplies the proven lifecycle and the intended copy/capture race semantics.
SQLite requires a different implementation: typed durable delta capture,
stable-locator/correspondence logic, bounded single-writer turns, dirty-key
validation, and a rigorously versioned transactional cutover. The remaining
hard questions—set reconciliation across new constraints, shadow-FK interaction
with parent DML, and archive rename correctness—are explicit fail-closed release
gates, not details to discover in production. V1 resolves the index-name problem
with an explicit logical→physical map, not `writable_schema`.

## Pre-release review findings

A pre-release review reproduced and fixed these defects before the first
release:

| Risk | Reproduced behavior | Resolution |
| --- | --- | --- |
| Data loss | Chained column renames copied NULL; remove/re-add copied the removed data instead of the new default | Track column lineage through ordered structured operations |
| Lost constraints | Rails' table rebuild silently dropped UNIQUE constraints and turned generated columns into stored columns | Reject unintended index/uniqueness/generated-column loss during scratch compilation |
| Lost caller work | A failed nested BEGIN rolled back the caller's open transaction | Reject nesting; roll back only transactions LiteHM opened |
| Wrong operation | Registration checked only the intent hash, so one id could alias another table or policy, or register in one file and enqueue another | Bind registration to table, adapter, policy, and actual database file |
| Broken live schema | Case-sensitive FK discovery missed `REFERENCES MESSAGES`; LIKE underscores hid application triggers; stale trigger bodies survived removed columns | Correct discovery; compile target trigger bodies and outbound FKs before execution |
| Lost migration state | Premature cleanup deleted correspondence before reporting that cutover had not happened | Check lifecycle before deleting artifacts |
| Validation bypass | Comment-separated conflict policies, connection-state functions, dynamic date/time arguments, and disabled CHECK enforcement passed checks | Sanitize conflict SQL, check SQLite function flags, reject dynamic time arguments, require CHECK enforcement |
| Parent-write outage | The original freeze refused all parent deletes and referenced-key updates until archive cleanup | `live_v1` journals/prunes temporary rows; source FK actions stay authoritative |
| Late invalidation | Large parent changes could invalidate several validated batches just before readiness | Validate every reconciled insertion batch, including target FKs, before commit |
| FK affinity mismatch | Validation used the child column's affinity where SQLite FK enforcement uses the parent's | Strip child-side affinity; parent text `'01'` must not accept child integer `1` |
| Recovery outage | Dropping a temporary table could leave parent triggers referencing it | Drop those triggers in the same transaction |
| Misleading lifecycle | `archive: :ephemeral` without FKs still retained an archive | Honor the ephemeral policy independently of FKs |
| Connection side effects | Missing paths created empty databases; borrowed connections kept LiteHM's busy timeout | Open existing files only; restore the caller's timeout |
| Upstream corruption | Default bundle used SQLite 3.47.0; runtime accepted releases with the WAL-reset bug | Require SQLite 3.51.3+ and sqlite3-ruby 2.9.6+ |
| Unreliable matrix | Inherited `BUNDLE_LOCKFILE` made compatibility runs overwrite the root lockfile | Clear inherited Bundler environment; one lockfile per matrix entry |

A runner-local SQLite version check cannot inspect other processes: every
writer and checkpointer must use a patched build.

The first rehearsal on a restored multi-gigabyte database (adding a
partial and a covering index to a large-JSON-payload table under a concurrent
writer with a 500 ms busy timeout) ran the original fixed 250-row batches.
Native `CREATE INDEX` blocked writes for about 27 seconds. LiteHM completed with
SIGKILL recovery, live parent deletions, and exact independent-replay
verification, but about 1.7% of writer attempts hit the 500 ms timeout and
copy transactions reached p99 of about 1 s against the nominal 75 ms target;
peak WAL was about 640 MB. That result drove the adaptive batching, pacing,
dedicated connection, checkpoint, and indexed-only FK pruning changes recorded
in the [writer-latency rehearsal](./writer-latency-rehearsal.md). Durable job
redelivery, operator pause/abort/manual cutover, and representative request
load on comparable storage remain deployment-specific validation.

[lhm-commit]: https://github.com/Shopify/lhm/tree/3374b6071d92a404da60d0295c268af5a2720641
[lhm-readme-idea]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/README.md#L37-L56
[lhm-api]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/lib/lhm.rb#L33-L102
[lhm-invoker]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/lib/lhm/invoker.rb#L50-L98
[lhm-migrator]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/lib/lhm/migrator.rb#L27-L194
[lhm-entangler]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/lib/lhm/entangler.rb#L18-L69
[lhm-chunker]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/lib/lhm/chunker.rb#L18-L117
[lhm-readme-archive]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/README.md#L108-L110
[lhm-readme-filter]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/README.md#L259-L282
[lhm-duplicate-pr]: https://github.com/Shopify/lhm/pull/100
[lhm-changelog]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/CHANGELOG.md#L1-L20
[lhm-rakefile]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/Rakefile#L7-L32
[lhm-integration]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/spec/integration/lhm_spec.rb
[lhm-entangler-tests]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/spec/integration/entangler_spec.rb
[lhm-chunker-tests]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/spec/integration/chunker_spec.rb
[lhm-ci]: https://github.com/Shopify/lhm/blob/3374b6071d92a404da60d0295c268af5a2720641/.github/workflows/test.yml#L9-L55
[dbix-tarball]: https://cpan.metacpan.org/authors/id/G/GS/GSG/DBIx-OnlineDDL-v1.1.2.tar.gz
[sqlite-alter]: https://sqlite.org/lang_altertable.html
[sqlite-create-table]: https://sqlite.org/lang_createtable.html
[sqlite-create-index]: https://sqlite.org/lang_createindex.html
[sqlite-transactions]: https://sqlite.org/lang_transaction.html
[sqlite-isolation]: https://sqlite.org/isolation.html
[sqlite-conflict]: https://sqlite.org/lang_conflict.html
[sqlite-upsert]: https://sqlite.org/lang_upsert.html
[sqlite-wal]: https://sqlite.org/wal.html
[sqlite-trigger]: https://sqlite.org/lang_createtrigger.html
[sqlite-strict]: https://sqlite.org/stricttables.html
[sqlite-without-rowid]: https://sqlite.org/withoutrowid.html
[sqlite-vacuum]: https://sqlite.org/lang_vacuum.html
[sqlite-fk-pragma]: https://sqlite.org/pragma.html#pragma_foreign_keys
[sqlite-foreign-keys]: https://sqlite.org/foreignkeys.html
[sqlite-writable-schema]: https://sqlite.org/pragma.html#pragma_writable_schema
[sqlite-schema-table]: https://sqlite.org/schematab.html
[sqlite-refill-index]: https://github.com/sqlite/sqlite/blob/ccc132c5be20ab5c755c97a08d06b1b592fef330/src/build.c#L3761-L3864
[sqlite-set-not-null]: https://github.com/sqlite/sqlite/blob/ccc132c5be20ab5c755c97a08d06b1b592fef330/src/alter.c#L2883-L2927
[sqlite-index-name]: https://github.com/sqlite/sqlite/blob/ccc132c5be20ab5c755c97a08d06b1b592fef330/src/build.c#L4059-L4095
[rails-adapter-config]: https://github.com/rails/rails/blob/v8.1.3.1/activerecord/lib/active_record/connection_adapters/sqlite3_adapter.rb#L111-L173
[rails-adapter-operations]: https://github.com/rails/rails/blob/v8.1.3.1/activerecord/lib/active_record/connection_adapters/sqlite3_adapter.rb#L354-L423
[rails-adapter-alter]: https://github.com/rails/rails/blob/v8.1.3.1/activerecord/lib/active_record/connection_adapters/sqlite3_adapter.rb#L591-L719
