# frozen_string_literal: true

require_relative "../test_helper"
require "active_job/test_helper"

# A worker killed without a graceful stop (SIGKILL, OOM, host reboot) is recorded
# as a failed execution by Solid Queue rather than redelivered. These tests drop
# the enqueued job to simulate that loss.
class StalledRecoveryTest < Minitest::Test
  include ActiveJob::TestHelper

  def setup
    @previous_mode = LiteHM.configuration.execution_mode
    @previous_stalled_after = LiteHM.configuration.stalled_after
    LiteHM.configuration.execution_mode = :async
    LiteHM.configuration.stalled_after = 600
    use_queue_adapter(:test)
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def teardown
    LiteHM.configuration.execution_mode = @previous_mode
    LiteHM.configuration.stalled_after = @previous_stalled_after
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def test_lost_job_is_reported_stalled_and_recovered_once_per_stall
    with_database do |path|
      submit(path, "lost-job")
      clear_enqueued_jobs
      refute LiteHM.status("lost-job", connection: path).stalled?, "a fresh submission is not stalled"

      backdate(path, "lost-job", seconds: 3_600)
      assert LiteHM.status("lost-job", connection: path).stalled?

      recovered = LiteHM.recover_stalled(connection: path)
      assert_equal ["lost-job"], recovered.map(&:plan_id)
      assert_equal 1, enqueued_jobs.size
      assert_equal "litehm", enqueued_jobs.first.fetch(:queue)
      assert_empty LiteHM.recover_stalled(connection: path), "the same stall is not re-enqueued twice"
      assert_equal 1, enqueued_jobs.size

      perform_enqueued_jobs
      status = LiteHM.status("lost-job", connection: path)
      assert status.cut_over?
      refute status.stalled?
    end
  end

  def test_a_recovery_that_also_disappears_is_retried_after_another_stall_window
    with_database do |path|
      submit(path, "lost-twice")
      clear_enqueued_jobs
      backdate(path, "lost-twice", seconds: 3_600)
      assert_equal 1, LiteHM.recover_stalled(connection: path).size
      clear_enqueued_jobs

      execute(path, "UPDATE litehm_plans SET recovery_enqueued_at = ?", iso(Time.now.utc - 3_600))
      assert_equal ["lost-twice"], LiteHM.recover_stalled(connection: path).map(&:plan_id)
      assert_equal 1, enqueued_jobs.size
    end
  end

  def test_live_writer_lease_means_a_runner_is_working
    with_database do |path|
      submit(path, "leased")
      clear_enqueued_jobs
      backdate(path, "leased", seconds: 3_600)
      expires = ((Time.now.to_f + 60) * 1_000).to_i
      execute(path, "INSERT INTO litehm_leases VALUES ('writer', 'someone', 1, ?)", expires)

      refute LiteHM.status("leased", connection: path).stalled?
      assert_empty LiteHM.recover_stalled(connection: path)
    end
  end

  def test_expired_lease_left_by_a_killed_runner_does_not_hide_the_stall
    with_database do |path|
      submit(path, "killed")
      clear_enqueued_jobs
      backdate(path, "killed", seconds: 3_600)
      expired = ((Time.now.to_f - 60) * 1_000).to_i
      execute(path, "INSERT INTO litehm_leases VALUES ('writer', 'dead-runner', 3, ?)", expired)

      assert_equal ["killed"], LiteHM.recover_stalled(connection: path).map(&:plan_id)
      perform_enqueued_jobs
      assert LiteHM.status("killed", connection: path).cut_over?
    end
  end

  def test_operator_states_are_not_stalls
    with_database do |path|
      submit(path, "paused-op")
      clear_enqueued_jobs
      LiteHM.pause("paused-op", connection: path)
      backdate(path, "paused-op", seconds: 3_600)
      refute LiteHM.status("paused-op", connection: path).stalled?
      assert_empty LiteHM.recover_stalled(connection: path)
    end

    with_database do |path|
      submit(path, "manual-gate", policy: { cutover: :manual })
      perform_enqueued_jobs
      assert LiteHM.status("manual-gate", connection: path).ready?
      backdate(path, "manual-gate", seconds: 3_600)
      refute LiteHM.status("manual-gate", connection: path).stalled?, "awaiting an operator, not a worker"
      assert_empty LiteHM.recover_stalled(connection: path)

      LiteHM.request_cutover("manual-gate", connection: path)
      clear_enqueued_jobs
      backdate(path, "manual-gate", seconds: 3_600)
      assert LiteHM.status("manual-gate", connection: path).stalled?, "a lost cutover request is a stall"
    end
  end

  def test_recovery_job_recovers_the_given_database
    with_database do |path|
      submit(path, "via-job")
      clear_enqueued_jobs
      backdate(path, "via-job", seconds: 3_600)

      LiteHM::RecoveryJob.perform_now(path)
      assert_equal [LiteHM::OperationJob], enqueued_jobs.map { |job| job.fetch(:job) }
      perform_enqueued_jobs
      assert LiteHM.status("via-job", connection: path).cut_over?
    end
  end

  private

  def use_queue_adapter(adapter)
    adapter = ActiveJob::QueueAdapters::TestAdapter.new if adapter == :test
    [ActiveJob::Base, LiteHM::OperationJob, LiteHM::RecoveryJob].each do |job_class|
      job_class.queue_adapter = adapter
      job_class.enable_test_adapter(adapter) if job_class.respond_to?(:enable_test_adapter)
    end
  end

  def submit(path, id, policy: {})
    LiteHM.change_table(:messages, id:, connection: path, policy:) do |table|
      table.add_column :flag, :integer, null: false, default: 0
    end
  end

  def backdate(path, id, seconds:)
    stamp = iso(Time.now.utc - seconds)
    execute(path, "UPDATE litehm_plans SET last_advanced_at = ?, updated_at = ? WHERE plan_id = ?",
      stamp, stamp, id)
  end

  def execute(path, sql, *binds)
    database = SQLite3::Database.new(path)
    database.execute(sql, binds)
  ensure
    database&.close
  end

  def iso(time)
    time.iso8601(6)
  end
end
