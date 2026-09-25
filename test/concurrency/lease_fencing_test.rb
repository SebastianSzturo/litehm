# frozen_string_literal: true

require_relative "../test_helper"

class LeaseFencingTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_live_runner_excludes_a_second_runner
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "lease-exclusive", connection: path,
        policy: { lease_ttl_ms: 1_000 }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      paused = Queue.new
      release = Queue.new
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_prepare_commit

        paused << true
        release.pop
      end
      first_error = nil
      first = Thread.new do
        LiteHM.run(plan)
      rescue StandardError => error
        first_error = error
      end
      first.report_on_exception = false
      first.join(0.01)
      paused.pop

      error = assert_raises(LiteHM::OperationConflict) { LiteHM.run(plan) }
      assert_match(/writer lease/, error.message)
      release << true
      first.join
      assert_nil first_error
      assert LiteHM.status(plan.id, connection: path).cut_over?
    ensure
      release << true if release && first&.alive?
      first&.join(1)
    end
  end

  def test_expired_runner_is_fenced_after_successor_finishes
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "lease-fence", connection: path,
        policy: { lease_ttl_ms: 20 }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      paused = Queue.new
      release = Queue.new
      pause_once = true
      stop_heartbeat = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        if point == :lease_heartbeat && stop_heartbeat
          raise LiteHM::LeaseConflict, "simulated lost heartbeat was fenced"
        end
        next unless point == :after_prepare_commit && pause_once

        pause_once = false
        stop_heartbeat = true
        paused << true
        release.pop
      end
      stale_error = nil
      stale = Thread.new do
        LiteHM.run(plan)
      rescue StandardError => error
        stale_error = error
      end
      stale.report_on_exception = false
      paused.pop
      sleep 0.03

      LiteHM::Testing.reset!
      successor = LiteHM.run(plan)
      assert successor.cut_over?
      release << true
      stale.join

      assert_instance_of LiteHM::LeaseConflict, stale_error
      assert_match(/fenced/, stale_error.message)
      assert_equal "cut_over", LiteHM.status(plan.id, connection: path).phase
    ensure
      release << true if release && stale&.alive?
      stale&.join(1)
    end
  end
end
