# frozen_string_literal: true

require_relative "../test_helper"
require "active_job/test_helper"

class StartPausedTest < Minitest::Test
  include ActiveJob::TestHelper

  def setup
    @previous_mode = LiteHM.configuration.execution_mode
    LiteHM.configuration.execution_mode = :async
    use_queue_adapter
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def teardown
    LiteHM.configuration.execution_mode = @previous_mode
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def test_paused_start_registers_without_enqueuing_or_touching_the_table
    with_database do |path|
      before = schema_snapshot(path)
      status = submit(path, "deferred", start: :paused)

      assert_equal "planned", status.phase
      assert status.paused?
      assert_equal "awaiting_start", status.pause_reason
      assert_empty enqueued_jobs
      assert_equal before, schema_snapshot(path).reject { |_, name, *| name.start_with?("litehm_") || name.start_with?("sqlite_autoindex_litehm_") },
        "no shadow table, triggers, or index changes before the operator starts it"
    end
  end

  def test_waiting_operation_is_not_stalled_and_recovery_leaves_it_alone
    with_database do |path|
      submit(path, "waiting", start: :paused)
      stale = (Time.now.utc - 86_400).iso8601(6)
      database = SQLite3::Database.new(path)
      database.execute("UPDATE litehm_plans SET last_advanced_at = ?, updated_at = ?", [stale, stale])
      database.close

      refute LiteHM.status("waiting", connection: path).stalled?
      assert_empty LiteHM.recover_stalled(connection: path)
      assert_empty enqueued_jobs
    end
  end

  def test_resume_starts_the_operation_and_it_runs_to_cutover
    with_database do |path|
      submit(path, "started-later", start: :paused)

      LiteHM.resume("started-later", connection: path)
      assert_equal 1, enqueued_jobs.size
      perform_enqueued_jobs

      status = LiteHM.status("started-later", connection: path)
      assert status.cut_over?
      assert_includes column_names(path), "flag"
    end
  end

  def test_resubmitting_a_started_plan_does_not_pause_it_again
    with_database do |path|
      submit(path, "resubmitted", start: :paused)
      LiteHM.resume("resubmitted", connection: path)
      clear_enqueued_jobs

      status = submit(path, "resubmitted", start: :paused)
      assert_equal "running", status.desired_state
      assert_equal 1, enqueued_jobs.size
    end
  end

  def test_revert_can_also_wait_to_be_started
    with_database do |path|
      submit(path, "forward")
      perform_enqueued_jobs
      clear_enqueued_jobs

      reverse = LiteHM.revert("forward", connection: path, start: :paused)
      assert_equal "planned", reverse.phase
      assert reverse.paused?
      assert_empty enqueued_jobs
    end
  end

  def test_inline_execution_runs_immediately
    with_database do |path|
      status = LiteHM.change_table(:messages, id: "inline", connection: path, execution: :inline,
        start: :paused) { |table| table.add_column :flag, :integer, null: false, default: 0 }
      assert status.cut_over?
    end
  end

  def test_rejects_unknown_start_values
    with_database do |path|
      assert_raises(ArgumentError) { submit(path, "bad", start: :later) }
    end
  end

  private

  def submit(path, id, start: :running)
    LiteHM.change_table(:messages, id:, connection: path, start:) do |table|
      table.add_column :flag, :integer, null: false, default: 0
    end
  end

  def column_names(path)
    database = SQLite3::Database.new(path)
    database.execute("PRAGMA table_info(messages)").map { |row| row[1] }
  ensure
    database&.close
  end

  def use_queue_adapter
    adapter = ActiveJob::QueueAdapters::TestAdapter.new
    [ActiveJob::Base, LiteHM::OperationJob, LiteHM::RecoveryJob].each do |job_class|
      job_class.queue_adapter = adapter
      job_class.enable_test_adapter(adapter) if job_class.respond_to?(:enable_test_adapter)
    end
  end
end
