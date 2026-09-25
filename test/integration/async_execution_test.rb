# frozen_string_literal: true

require_relative "../test_helper"
require "active_job/test_helper"

class AsyncExecutionTest < Minitest::Test
  include ActiveJob::TestHelper

  SimulatedCrash = Class.new(StandardError)

  class FailingQueueAdapter < ActiveJob::QueueAdapters::TestAdapter
    def enqueue(_job)
      raise "queue unavailable"
    end
  end

  class FailingRetryQueueAdapter < ActiveJob::QueueAdapters::TestAdapter
    def enqueue_at(_job, _timestamp)
      raise ActiveJob::EnqueueError, "continuation queue unavailable"
    end
  end

  def setup
    @previous_mode = LiteHM.configuration.execution_mode
    @previous_queue = LiteHM.configuration.queue_name
    LiteHM.configuration.execution_mode = :async
    LiteHM.configuration.queue_name = :litehm
    use_queue_adapter(:test)
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def teardown
    LiteHM::Testing.reset!
    LiteHM.configuration.execution_mode = @previous_mode
    LiteHM.configuration.queue_name = @previous_queue
    use_queue_adapter(:test)
    ActiveJob::Base.queue_adapter.stopping = false
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def test_change_table_submits_to_the_dedicated_queue_and_returns_before_copy
    with_database do |path|
      submitted = LiteHM.change_table(:messages, id: "async-default", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      assert_equal "planned", submitted.phase
      assert_equal %w[id body sent_at metadata], column_names(path)
      job = enqueued_jobs.fetch(0)
      assert_equal "litehm", job.fetch(:queue)
      assert_equal LiteHM::OperationJob, job.fetch(:job)

      perform_enqueued_jobs

      assert_equal %w[id body sent_at metadata flag], column_names(path)
      assert LiteHM.status("async-default", connection: path).cut_over?
    end
  end

  def test_continuation_checkpoints_resume_after_a_graceful_worker_stop
    with_database do |path|
      fill(path, 800)
      LiteHM.change_table(:messages, id: "continuable", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      ActiveJob::Base.queue_adapter.stopping = true
      execute_next_job

      interrupted = LiteHM.status("continuable", connection: path)
      assert_equal "preparing", interrupted.phase
      assert_operator interrupted.execution_revision, :>, 0
      assert_operator enqueued_jobs.length, :>, 0

      ActiveJob::Base.queue_adapter.stopping = false
      execute_all_jobs

      final = LiteHM.status("continuable", connection: path)
      assert final.cut_over?
      assert_equal 802, row_count(path, "messages")
      assert_equal "ok", integrity(path)
    end
  end

  def test_pause_and_resume_are_observed_at_a_committed_batch_boundary
    with_database do |path|
      fill(path, 600)
      paused = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :execution_checkpoint && context.fetch(:kind) == :copy && !paused

        paused = true
        LiteHM.pause("pause-resume", connection: path)
      end
      LiteHM.change_table(:messages, id: "pause-resume", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      perform_enqueued_jobs
      stopped = LiteHM.status("pause-resume", connection: path)
      assert stopped.paused?
      assert_equal "preparing", stopped.phase
      assert_operator stopped.progress.fetch("copied_rows"), :>, 0
      assert_operator stopped.progress.fetch("copied_rows"), :<, 602

      LiteHM::Testing.reset!
      LiteHM.resume("pause-resume", connection: path)
      perform_enqueued_jobs

      assert LiteHM.status("pause-resume", connection: path).cut_over?
      assert_equal 602, row_count(path, "messages")
    end
  end

  def test_manual_cutover_and_archive_cleanup_are_separate_async_commands
    with_database do |path|
      LiteHM.change_table(:messages, id: "manual-cutover", connection: path,
        policy: { cutover: :manual }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      perform_enqueued_jobs

      ready = LiteHM.status("manual-cutover", connection: path)
      assert ready.ready?
      assert_equal %w[id body sent_at metadata], column_names(path)

      LiteHM.request_cutover("manual-cutover", connection: path)
      assert_equal "cutover_requested",
        LiteHM.status("manual-cutover", connection: path).desired_state
      perform_enqueued_jobs
      cut_over = LiteHM.status("manual-cutover", connection: path)
      assert cut_over.cut_over?
      assert_equal "running", cut_over.desired_state
      assert_equal %w[id body sent_at metadata flag], column_names(path)

      LiteHM.request_cleanup("manual-cutover", connection: path)
      assert_equal "cleanup_requested",
        LiteHM.status("manual-cutover", connection: path).desired_state
      perform_enqueued_jobs
      done = LiteHM.status("manual-cutover", connection: path)
      assert_equal "done", done.phase
      assert_equal "running", done.desired_state
    end
  end

  def test_abort_command_stops_a_partially_copied_operation_without_changing_source
    with_database do |path|
      fill(path, 400)
      paused = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :execution_checkpoint && context.fetch(:kind) == :copy && !paused

        paused = true
        LiteHM.pause("async-abort", connection: path)
      end
      LiteHM.change_table(:messages, id: "async-abort", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      perform_enqueued_jobs
      LiteHM::Testing.reset!

      LiteHM.request_abort("async-abort", connection: path)
      perform_enqueued_jobs

      assert_equal "aborted", LiteHM.status("async-abort", connection: path).phase
      assert_equal %w[id body sent_at metadata], column_names(path)
      assert_equal 402, row_count(path, "messages")
    end
  end

  def test_permanent_failure_is_visible_and_operator_retry_resumes_same_plan
    with_database do |path|
      LiteHM.change_table(:messages, id: "async-retry", connection: path) do |table|
        table.add_index :body, unique: true
      end
      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO messages(body) VALUES ('hello')")
      database.close

      assert_raises(LiteHM::DataIncompatible) { perform_enqueued_jobs }
      failed = LiteHM.status("async-retry", connection: path)
      assert failed.paused?
      assert_equal "LiteHM::DataIncompatible", failed.error.fetch("class")

      database = SQLite3::Database.new(path)
      database.execute("DELETE FROM messages WHERE id = (SELECT MAX(id) FROM messages)")
      database.close
      LiteHM.retry_operation("async-retry", connection: path)
      perform_enqueued_jobs

      final = LiteHM.status("async-retry", connection: path)
      assert final.cut_over?
      assert_nil final.error
    ensure
      database&.close
    end
  end

  def test_revert_is_asynchronous_by_default
    with_database do |path|
      LiteHM.change_table(:messages, id: "async-forward", connection: path) do |table|
        table.rename_column :body, :content
      end
      perform_enqueued_jobs
      assert_equal %w[id content sent_at metadata], column_names(path)

      submitted = LiteHM.revert("async-forward", connection: path)
      assert_equal "planned", submitted.phase
      assert_equal %w[id content sent_at metadata], column_names(path)
      perform_enqueued_jobs

      assert_equal %w[id body sent_at metadata], column_names(path)
      assert LiteHM.status("revert_async-forward", connection: path).cut_over?
    end
  end

  def test_enqueue_failure_is_persisted_and_can_be_retried_from_the_engine_contract
    with_database do |path|
      use_queue_adapter(FailingQueueAdapter.new)

      assert_raises(RuntimeError) do
        LiteHM.change_table(:messages, id: "enqueue-retry", connection: path) do |table|
          table.add_column :flag, :integer, null: false, default: 0
        end
      end
      failed = LiteHM.status("enqueue-retry", connection: path)
      assert_equal "running", failed.desired_state
      assert_equal "queue unavailable", failed.error.fetch("message")

      use_queue_adapter(:test)
      LiteHM.retry_operation("enqueue-retry", connection: path)
      perform_enqueued_jobs
      assert LiteHM.status("enqueue-retry", connection: path).cut_over?
    ensure
      use_queue_adapter(:test)
    end
  end

  def test_enqueue_failure_preserves_a_pending_abort_command
    with_database do |path|
      LiteHM.change_table(:messages, id: "abort-enqueue-retry", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      clear_enqueued_jobs
      use_queue_adapter(FailingQueueAdapter.new)

      assert_raises(RuntimeError) do
        LiteHM.request_abort("abort-enqueue-retry", connection: path)
      end
      failed = LiteHM.status("abort-enqueue-retry", connection: path)
      assert_equal "abort_requested", failed.desired_state
      assert_equal "queue unavailable", failed.error.fetch("message")

      use_queue_adapter(:test)
      LiteHM.retry_operation("abort-enqueue-retry", connection: path)
      perform_enqueued_jobs
      assert_equal "aborted", LiteHM.status("abort-enqueue-retry", connection: path).phase
    ensure
      use_queue_adapter(:test)
    end
  end

  def test_failed_continuation_reenqueue_is_raised_for_backend_redelivery
    with_database do |path|
      fill(path, 600)
      LiteHM.change_table(:messages, id: "continuation-enqueue-failure", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      payload = enqueued_jobs.shift
      use_queue_adapter(FailingRetryQueueAdapter.new)
      ActiveJob::Base.queue_adapter.stopping = true

      error = assert_raises(ActiveJob::EnqueueError) { ActiveJob::Base.execute(payload) }
      assert_match(/continuation queue unavailable/, error.message)
      interrupted = LiteHM.status("continuation-enqueue-failure", connection: path)
      assert_equal "preparing", interrupted.phase
      assert_equal "running", interrupted.desired_state
      assert_equal "ActiveJob::EnqueueError", interrupted.error.fetch("class")

      use_queue_adapter(:test)
      ActiveJob::Base.execute(payload)
      recovered = LiteHM.status("continuation-enqueue-failure", connection: path)
      assert recovered.cut_over?
      assert_nil recovered.error
    ensure
      use_queue_adapter(:test)
    end
  end

  def test_abort_command_survives_process_death_before_action_dispatch
    with_database do |path|
      LiteHM.change_table(:messages, id: "abort-dispatch-crash", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      clear_enqueued_jobs
      LiteHM.request_abort("abort-dispatch-crash", connection: path)
      payload = enqueued_jobs.shift

      pid = fork do
        LiteHM::Testing.fault_injector = lambda do |point, _context|
          Process.kill("KILL", Process.pid) if point == :before_operation_action
        end
        ActiveJob::Base.execute(payload)
      end
      _dead_pid, crash = Process.wait2(pid)
      assert crash.signaled?
      assert_equal "abort_requested",
        LiteHM.status("abort-dispatch-crash", connection: path).desired_state

      ActiveJob::Base.execute(payload)
      assert_equal "aborted", LiteHM.status("abort-dispatch-crash", connection: path).phase
    end
  end

  def test_failure_after_an_abort_request_does_not_overwrite_the_command
    with_database do |path|
      fill(path, 400)
      requested = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_copy_batch_commit && !requested

        requested = true
        LiteHM.request_abort("abort-before-failure", connection: path)
        raise LiteHM::ValidationFailed, "injected after command"
      end
      LiteHM.change_table(:messages, id: "abort-before-failure", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      assert_raises(LiteHM::ValidationFailed) { execute_next_job }
      interrupted = LiteHM.status("abort-before-failure", connection: path)
      assert_equal "abort_requested", interrupted.desired_state
      assert_equal "LiteHM::ValidationFailed", interrupted.error.fetch("class")

      LiteHM::Testing.reset!
      execute_all_jobs
      final = LiteHM.status("abort-before-failure", connection: path)
      assert_equal "aborted", final.phase
      assert_nil final.error
      assert_equal %w[id body sent_at metadata], column_names(path)
    end
  end

  def test_abort_resumes_from_durable_aborting_phase_after_process_death
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "abort-phase-crash", connection: path,
        policy: { lease_ttl_ms: 50 }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      assert LiteHM.run(plan, through: :ready, connection: path).ready?
      LiteHM.request_abort(plan.id, connection: path)
      payload = enqueued_jobs.shift

      pid = fork do
        LiteHM::Testing.fault_injector = lambda do |point, _context|
          Process.kill("KILL", Process.pid) if point == :after_abort_started
        end
        ActiveJob::Base.execute(payload)
      end
      _dead_pid, crash = Process.wait2(pid)
      assert crash.signaled?
      interrupted = LiteHM.status(plan.id, connection: path)
      assert_equal "aborting", interrupted.phase
      assert_equal "abort_requested", interrupted.desired_state

      sleep 0.07
      ActiveJob::Base.execute(payload)
      assert_equal "aborted", LiteHM.status(plan.id, connection: path).phase
    end
  end

  def test_abort_at_ready_checkpoint_prevents_cutover
    with_database do |path|
      requested = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_ready_commit && !requested

        requested = true
        LiteHM.request_abort("abort-at-ready", connection: path)
      end
      LiteHM.change_table(:messages, id: "abort-at-ready", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      execute_all_jobs
      final = LiteHM.status("abort-at-ready", connection: path)
      assert_equal "aborted", final.phase
      assert_equal %w[id body sent_at metadata], column_names(path)
    end
  end

  def test_abort_requested_at_cutover_acquisition_wins_before_schema_swap
    with_database do |path|
      requested = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_cutover_acquire && !requested

        requested = true
        LiteHM.request_abort("abort-at-cutover", connection: path)
      end
      LiteHM.change_table(:messages, id: "abort-at-cutover", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      execute_all_jobs
      final = LiteHM.status("abort-at-cutover", connection: path)
      assert_equal "aborted", final.phase
      assert_equal "running", final.desired_state
      assert_equal %w[id body sent_at metadata], column_names(path)
    end
  end

  def test_validation_resumes_from_its_durable_cursor
    with_database do |path|
      fill(path, 700)
      paused = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :execution_checkpoint && context.fetch(:kind) == :validate_source && !paused

        paused = true
        LiteHM.pause("validation-cursor", connection: path)
      end
      LiteHM.change_table(:messages, id: "validation-cursor", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      perform_enqueued_jobs
      interrupted = LiteHM.status("validation-cursor", connection: path)
      encoded_cursor = interrupted.progress.fetch("validation_source_cursor")

      observed = []
      LiteHM::Testing.fault_injector = lambda do |point, context|
        observed << context[:cursor] if point == :before_validate_source_batch
      end
      LiteHM.resume("validation-cursor", connection: path)
      perform_enqueued_jobs

      assert_equal LiteHM::ValueCodec.decode_row(encoded_cursor), observed.first
      assert LiteHM.status("validation-cursor", connection: path).cut_over?
    end
  end

  def test_reconciliation_invalidates_a_stale_validation_cursor
    with_database do |path|
      fill(path, 700)
      paused = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :execution_checkpoint && context.fetch(:kind) == :validate_source && !paused

        paused = true
        LiteHM.pause("validation-reset", connection: path)
      end
      LiteHM.change_table(:messages, id: "validation-reset", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      perform_enqueued_jobs
      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO messages(body) VALUES ('arrived-after-validation')")
      database.close

      observed = []
      LiteHM::Testing.fault_injector = lambda do |point, context|
        observed << context[:cursor] if point == :before_validate_source_batch
      end
      LiteHM.resume("validation-reset", connection: path)
      perform_enqueued_jobs

      assert_nil observed.first
      assert LiteHM.status("validation-reset", connection: path).cut_over?
    ensure
      database&.close
    end
  end

  def test_reconciliation_commits_validation_cursor_invalidation_before_checkpoint
    with_database do |path|
      fill(path, 700)
      paused = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :execution_checkpoint && context.fetch(:kind) == :validate_source && !paused

        paused = true
        LiteHM.pause("validation-reset-crash", connection: path)
      end
      LiteHM.change_table(:messages, id: "validation-reset-crash", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      perform_enqueued_jobs
      assert LiteHM.status("validation-reset-crash", connection: path).progress
        .key?("validation_source_cursor")

      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO messages(body) VALUES ('arrived-before-crash')")
      database.close
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        raise SimulatedCrash if point == :after_reconcile_batch_commit
      end

      LiteHM.resume("validation-reset-crash", connection: path)
      assert_raises(SimulatedCrash) { perform_enqueued_jobs }
      interrupted = LiteHM.status("validation-reset-crash", connection: path)
      refute interrupted.progress.key?("validation_source_cursor")
      refute interrupted.progress.key?("validation_target_cursor")

      LiteHM::Testing.reset!
      LiteHM.retry_operation("validation-reset-crash", connection: path)
      perform_enqueued_jobs
      assert LiteHM.status("validation-reset-crash", connection: path).cut_over?
    ensure
      database&.close
    end
  end

  def test_automatic_fk_archive_cleanup_keeps_the_continuation_callback
    Dir.mktmpdir("litehm-async-fk-cleanup") do |directory|
      path = File.join(directory, "cleanup.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE parents(id INTEGER PRIMARY KEY);
        CREATE TABLE messages(
          id INTEGER PRIMARY KEY,
          parent_id INTEGER NOT NULL REFERENCES parents(id),
          body TEXT NOT NULL
        );
        CREATE INDEX messages_parent ON messages(parent_id);
        INSERT INTO parents VALUES (1);
      SQL
      database.transaction do
        700.times do |index|
          database.execute("INSERT INTO messages VALUES (?, 1, ?)",
            [index + 1, "message-#{index}"])
        end
      end
      database.close

      stopping = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_cleanup_batch && !stopping

        stopping = true
        ActiveJob::Base.queue_adapter.stopping = true
      end
      LiteHM.change_table(:messages, id: "continuable-fk-cleanup", connection: path,
        policy: { archive: :ephemeral }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      execute_next_job
      interrupted = LiteHM.status("continuable-fk-cleanup", connection: path)
      assert_equal "archive_released", interrupted.phase
      assert_operator enqueued_jobs.length, :>, 0

      ActiveJob::Base.queue_adapter.stopping = false
      LiteHM::Testing.reset!
      execute_all_jobs
      assert_equal "done", LiteHM.status("continuable-fk-cleanup", connection: path).phase
      assert_equal 700, row_count(path, "messages")
      assert_equal "ok", integrity(path)
    ensure
      database&.close
    end
  end

  def test_permanent_operation_conflict_is_visible_instead_of_retried_forever
    with_database do |path|
      LiteHM.change_table(:messages, id: "artifact-conflict-async", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      database = SQLite3::Database.new(path)
      artifact = LiteHM::SQL.artifact("shadow", "artifact-conflict-async")
      database.execute("CREATE TABLE #{LiteHM::SQL.identifier(artifact)}(id INTEGER)")
      database.close

      assert_raises(LiteHM::OperationConflict) { perform_enqueued_jobs }
      failed = LiteHM.status("artifact-conflict-async", connection: path)
      assert failed.paused?
      assert_equal "LiteHM::OperationConflict", failed.error.fetch("class")
      assert_empty enqueued_jobs
    ensure
      database&.close
    end
  end

  private

  def use_queue_adapter(adapter)
    adapter = ActiveJob::QueueAdapters::TestAdapter.new if adapter == :test
    [ActiveJob::Base, LiteHM::OperationJob].each do |job_class|
      job_class.queue_adapter = adapter
      job_class.enable_test_adapter(adapter) if job_class.respond_to?(:enable_test_adapter)
    end
  end

  def execute_next_job
    job = enqueued_jobs.shift
    raise "no enqueued job" unless job

    ActiveJob::Base.execute(job)
  end

  def execute_all_jobs
    execute_next_job while enqueued_jobs.any?
  end

  def column_names(path)
    database = SQLite3::Database.new(path)
    database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
  ensure
    database&.close
  end

  def fill(path, count)
    database = SQLite3::Database.new(path)
    database.transaction do
      count.times do |index|
        database.execute(
          "INSERT INTO messages(body, sent_at) VALUES (?, ?)", ["bulk-#{index}", index + 100]
        )
      end
    end
  ensure
    database&.close
  end

  def row_count(path, table)
    database = SQLite3::Database.new(path)
    database.get_first_value("SELECT COUNT(*) FROM #{LiteHM::SQL.identifier(table)}")
  ensure
    database&.close
  end

  def integrity(path)
    database = SQLite3::Database.new(path)
    database.get_first_value("PRAGMA integrity_check")
  ensure
    database&.close
  end
end
