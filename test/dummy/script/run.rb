# frozen_string_literal: true

require "json"
require "base64"
require "open3"

ENV["RAILS_ENV"] = "test"
ENV["LITEHM_DUMMY_DATABASE"] = File.expand_path(ARGV.fetch(0))
require_relative "../config/environment"

adapter = ActiveJob::Base.queue_adapter
adapter.enqueued_jobs.clear
adapter.performed_jobs.clear

ActiveRecord::Schema.define do
  create_table :messages, force: true do |table|
    table.text :body, null: false
    table.integer :sent_at
  end
end

database = ActiveRecord::Base.connection.raw_connection
database.transaction do
  statement = database.prepare("INSERT INTO messages(body, sent_at) VALUES (?, ?)")
  100_000.times { |index| statement.execute("message-#{index}", index) }
  statement.close
end

migrations = File.expand_path("../db/migrate", __dir__)
pool = ActiveRecord::Base.connection_pool
context = ActiveRecord::MigrationContext.new(migrations, pool.schema_migration, pool.internal_metadata)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
context.migrate
migration_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
submitted_columns = ActiveRecord::Base.connection.execute("PRAGMA table_xinfo(messages)").map { |row| row["name"] }
submitted = LiteHM.status("dummy-messages-search", connection: ActiveRecord::Base.connection)
initial_job = adapter.enqueued_jobs.shift

unauthorized = ActionDispatch::Integration::Session.new(Rails.application)
unauthorized.get("/litehm")
authorized = ActionDispatch::Integration::Session.new(Rails.application)
authorized.get("/litehm", headers: { "X-LiteHM-Token" => "dummy-secret" })
authorized_status = authorized.response.status
index_body = authorized.response.body
icon = ActionDispatch::Integration::Session.new(Rails.application)
icon.get("/litehm/icon.png", headers: { "X-LiteHM-Token" => "dummy-secret" })
unauthorized_icon = ActionDispatch::Integration::Session.new(Rails.application)
unauthorized_icon.get("/litehm/icon.png")

# Exercise engine commands before starting the worker.
authorized.post("/litehm/operations/dummy-messages-search/command",
  params: { operation_command: "pause" }, headers: { "X-LiteHM-Token" => "dummy-secret" })
paused = LiteHM.status("dummy-messages-search", connection: ActiveRecord::Base.connection)
authorized.post("/litehm/operations/dummy-messages-search/command",
  params: { operation_command: "resume" }, headers: { "X-LiteHM-Token" => "dummy-secret" })
adapter.enqueued_jobs.clear
adapter.enqueued_jobs << initial_job

# A graceful deploy stop interrupts at the first committed checkpoint and
# serializes the continuation back into the job payload.
adapter.stopping = true
ActiveJob::Base.execute(adapter.enqueued_jobs.shift)
adapter.stopping = false
resumed_job = adapter.enqueued_jobs.shift
resumed_job = JSON.parse(JSON.generate(resumed_job))

# Simulate a hard worker crash after a committed copy batch. Redelivering the
# same payload must resume from the target database ledger, not job memory.
pid = fork do
  LiteHM::Testing.fault_injector = lambda do |point, _context|
    Process.kill("KILL", Process.pid) if point == :after_copy_batch_commit
  end
  ActiveJob::Base.execute(resumed_job)
end
_, crash_status = Process.wait2(pid)
raise "expected the dummy worker to be killed" unless crash_status.signaled?
sleep 0.15

ActiveRecord::Base.connection.execute(
  "INSERT INTO messages(body, sent_at) VALUES ('arrived-during-deploy', 30000)"
)
encoded_job = Base64.strict_encode64(JSON.generate(resumed_job))
worker = File.expand_path("execute_job.rb", __dir__)
worker_stdout, worker_stderr, worker_status = Open3.capture3(
  { "RAILS_ENV" => "test" }, Gem.ruby, worker, ENV.fetch("LITEHM_DUMMY_DATABASE"), encoded_job,
  chdir: Rails.root
)
unless worker_status.success?
  raise "restarted dummy worker failed:\n#{worker_stdout}\n#{worker_stderr}"
end

final = LiteHM.status("dummy-messages-search", connection: ActiveRecord::Base.connection)
final_columns = ActiveRecord::Base.connection.execute("PRAGMA table_xinfo(messages)").map { |row| row["name"] }
row_count = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM messages")
index_names = ActiveRecord::Base.connection.indexes(:messages).map(&:name)
authorized.get("/litehm/operations/dummy-messages-search",
  headers: { "X-LiteHM-Token" => "dummy-secret" })

show_body = authorized.response.body
original_progress = final.progress
# Exercise explicit and legacy capped samples through the real engine view.
database.execute("UPDATE litehm_plans SET progress_json = ? WHERE plan_id = ?",
  [JSON.generate(original_progress.merge("dirty_rows" => 251, "dirty_rows_exact" => false)), final.plan_id])
authorized.get("/litehm/operations/dummy-messages-search", headers: { "X-LiteHM-Token" => "dummy-secret" })
capped_sample_visible = authorized.response.body.include?("At least 251")
legacy_progress = original_progress.merge("dirty_rows" => 251).except("dirty_rows_exact")
database.execute("UPDATE litehm_plans SET progress_json = ? WHERE plan_id = ?",
  [JSON.generate(legacy_progress), final.plan_id])
authorized.get("/litehm/operations/dummy-messages-search", headers: { "X-LiteHM-Token" => "dummy-secret" })
legacy_sample_visible = authorized.response.body.include?("At least 251")
database.execute("UPDATE litehm_plans SET progress_json = ? WHERE plan_id = ?",
  [JSON.generate(original_progress), final.plan_id])
# A lost cleanup request with no live runner renders as stalled with a retry.
stale = (Time.now.utc - 3_600).iso8601(6)
original_row = database.get_first_row(
  "SELECT desired_state, last_advanced_at, updated_at FROM litehm_plans WHERE plan_id = ?", [final.plan_id]
)
database.execute("UPDATE litehm_plans SET desired_state = 'cleanup_requested', last_advanced_at = ?, updated_at = ? WHERE plan_id = ?",
  [stale, stale, final.plan_id])
authorized.get("/litehm/operations/dummy-messages-search", headers: { "X-LiteHM-Token" => "dummy-secret" })
stalled_visible = authorized.response.body.include?("Stalled") && authorized.response.body.include?("Retry now")
database.execute("UPDATE litehm_plans SET desired_state = ?, last_advanced_at = ?, updated_at = ? WHERE plan_id = ?",
  [*original_row.values_at("desired_state", "last_advanced_at", "updated_at"), final.plan_id])

# An operation registered with start: :paused waits for an operator to start it.
LiteHM.change_table(:messages, id: "dummy-deferred", connection: ActiveRecord::Base.connection,
  start: :paused) { |table| table.add_column :deferred_flag, :integer, null: false, default: 0 }
authorized.get("/litehm/operations/dummy-deferred", headers: { "X-LiteHM-Token" => "dummy-secret" })
deferred_visible = authorized.response.body.include?("Waiting to be started") &&
  authorized.response.body.include?(">Start<")

puts JSON.generate(
  migration_seconds:,
  submitted_phase: submitted.phase.to_s,
  submitted_copied_rows: submitted.progress.fetch("copied_rows", 0),
  submitted_jobs_performed: adapter.performed_jobs.size,
  submitted_columns:,
  migration_version_recorded: context.get_all_versions.include?(20_260_819_000_000),
  queue: initial_job.fetch(:queue),
  unauthorized_status: unauthorized.response.status,
  authorized_status:,
  index_page_includes_plan: index_body.include?("dummy-messages-search"),
  index_page_links_icon: index_body.include?(%(rel="icon" type="image/png" href="/litehm/icon.png")),
  icon_status: icon.response.status,
  icon_content_type: icon.response.media_type,
  icon_cache_control: icon.response.headers["Cache-Control"],
  icon_png: icon.response.body.b.start_with?("\x89PNG".b),
  unauthorized_icon_status: unauthorized_icon.response.status,
  paused: paused.paused?,
  crash_signal: crash_status.termsig,
  restarted_worker: worker_status.success?,
  final_phase: final.phase,
  final_columns:,
  row_count:,
  index_names:,
  show_status: authorized.response.status,
  cache_control: authorized.response.headers["Cache-Control"],
  show_includes_progress: show_body.include?("Copied rows"),
  show_includes_metrics: show_body.include?("Worker metrics") && show_body.include?("Throughput by stage"),
  show_includes_checkpoint: show_body.include?("Pending frames"),
  persisted_copy_rows: final.telemetry.dig("stages", "copy", "rows"),
  capped_sample_visible:, legacy_sample_visible:, stalled_visible:, deferred_visible:,

  integrity: ActiveRecord::Base.connection.select_value("PRAGMA integrity_check")
)
