# frozen_string_literal: true

# Renders the engine for one operation in every state the dashboard maps, and
# prints what each page contains as JSON for EngineStatesTest.
require "json"

ENV["RAILS_ENV"] = "test"
ENV["LITEHM_DUMMY_DATABASE"] = File.expand_path(ARGV.fetch(0))
require_relative "../config/environment"

connection = ActiveRecord::Base.connection
database = connection.raw_connection
now = Time.now.utc
at = ->(seconds_ago) { (now - seconds_ago).iso8601(6) }
integer = ->(value) { [{ "type" => "integer", "value" => value }] }

telemetry = lambda do |stage, rows: 0, rate: nil|
  { "version" => 1, "execution_id" => "x", "started_at" => at.call(600), "sampled_at" => at.call(4),
    "stage" => stage, "elapsed_ms" => 600_000,
    "stages" => { stage => { "rows" => rows, "batches" => 3, "elapsed_ms" => 1000.0, "transaction_ms" => 20.0,
      "max_transaction_ms" => 14.2, "rows_per_second" => rate } },
    "lock_wait_ms" => 312.0, "lock_retries" => 3, "rollbacks" => 0,
    "last_batch" => { "kind" => stage, "rows" => 20, "committed" => true, "transaction_ms" => 8.9,
      "lock_wait_ms" => 0.1, "next_rows" => 2000, "pause_ms" => 11.0, "pause_reason" => "writer_duty_cycle" },
    "last_retry" => nil,
    "checkpoint" => { "sampled_at" => at.call(5), "duration_ms" => 2.4, "status" => "sampled", "busy" => 0,
      "log_frames" => 4096, "checkpointed_frames" => 3978, "pending_frames" => 118 } }.compact
end

copy_progress = lambda do |cursor, dirty: 37, exact: true|
  { "copy_cursor" => integer.call(cursor), "copy_upper_bound" => integer.call(1000),
    "copy_lower_bound" => integer.call(1), "copied_rows" => cursor, "dirty_rows" => dirty,
    "dirty_rows_exact" => exact }
end
done_progress = { "copy_cursor" => integer.call(1000), "copy_upper_bound" => integer.call(1000),
  "copy_lower_bound" => integer.call(1), "copied_rows" => 1000, "dirty_rows" => 0, "dirty_rows_exact" => true }
not_null_error = { "class" => "LiteHM::DataIncompatible",
  "message" => "source projection violates a target constraint during copy",
  "details" => { "sqlite_error" => "NOT NULL constraint failed: __litehm_shadow_2a969c41e8.country_code" } }
receipt = ->(phase) { { "plan_id" => "x", "phase" => phase, "cutover_at" => at.call(86_400 * 3) } }

scenarios = {
  "waiting" => { phase: "planned", desired: "paused" },
  "queued" => { phase: "planned", desired: "running" },
  "running" => { phase: "preparing", progress: copy_progress.call(427).merge("telemetry" => telemetry.call("copy", rows: 420, rate: 50.0)) },
  "paused" => { phase: "preparing", desired: "paused", progress: copy_progress.call(610, dirty: 251, exact: false) },
  "catching_up" => { phase: "preparing", progress: done_progress.merge("telemetry" => telemetry.call("reconcile", rows: 12)) },
  "validating" => { phase: "preparing", progress: done_progress.merge("validation_source_cursor" => integer.call(10)) },
  "ready" => { phase: "ready", policy: { cutover: :manual }, progress: done_progress },
  "ready_automatic" => { phase: "ready", progress: done_progress },
  "cutover_requested" => { phase: "ready", desired: "cutover_requested", policy: { cutover: :manual }, progress: done_progress },
  "failed" => { phase: "preparing", desired: "paused", error: not_null_error, progress: copy_progress.call(259) },
  "failed_unpaused" => { phase: "preparing", desired: "running", error: not_null_error, stale: true, progress: copy_progress.call(259) },
  "stalled" => { phase: "preparing", stale: true, progress: done_progress },
  "abort_requested" => { phase: "preparing", desired: "abort_requested", progress: copy_progress.call(100) },
  "aborting" => { phase: "aborting", progress: copy_progress.call(100) },
  "live_archive" => { phase: "cut_over", archive: { "name" => "__litehm_archive_x", "state" => "retained" },
    receipt: receipt.call("cut_over"), progress: done_progress },
  "releasing" => { phase: "archive_released", archive: { "name" => "__litehm_archive_x", "state" => "releasing" },
    receipt: receipt.call("archive_released"), progress: done_progress, desired: "cleanup_requested" },
  "done" => { phase: "done", archive: { "name" => "__litehm_archive_x", "state" => "released" },
    receipt: receipt.call("done"), progress: done_progress },
  "aborted" => { phase: "aborted", progress: copy_progress.call(100) },
  # Stored by an older LiteHM: no lower bound, no explicit sample cap, no telemetry.
  "legacy" => { phase: "preparing", progress: { "copy_cursor" => integer.call(500), "copy_upper_bound" => integer.call(1000),
    "copied_rows" => 500, "dirty_rows" => 251 } }
}

scenarios.each do |name, scenario|
  table = "t_#{name}"
  connection.execute("CREATE TABLE #{table} (id INTEGER PRIMARY KEY, value INTEGER)")
  connection.execute("INSERT INTO #{table}(value) VALUES (1), (2), (3)")
  plan = LiteHM.plan(table.to_sym, id: "state-#{name}", connection:, policy: scenario.fetch(:policy, {})) do |target|
    target.add_index :value, name: "#{table}_value"
  end
  LiteHM.run(plan, through: :planned, connection:)
  touched = scenario[:stale] ? at.call(3_600) : at.call(3)
  binds = [scenario.fetch(:phase), scenario.fetch(:desired, "running"),
    JSON.generate(scenario.fetch(:progress, {})), scenario[:error] && JSON.generate(scenario[:error]),
    JSON.generate(scenario.fetch(:archive, {})), scenario[:receipt] && JSON.generate(scenario[:receipt]),
    touched, touched, plan.id]
  database.execute(<<~SQL, binds)
    UPDATE litehm_plans SET phase = ?, desired_state = ?, progress_json = ?, error_json = ?,
      archive_json = ?, receipt_json = ?, last_advanced_at = ?, updated_at = ?
    WHERE plan_id = ?
  SQL
end

session = ActionDispatch::Integration::Session.new(Rails.application)
headers = { "X-LiteHM-Token" => "dummy-secret" }
session.get("/litehm", headers:)
index = { "status" => session.response.status, "body" => session.response.body }
pages = scenarios.keys.to_h do |name|
  session.get("/litehm/operations/state-#{name}", headers:)
  [name, { "status" => session.response.status, "body" => session.response.body }]
end

puts JSON.generate(index:, pages:)
