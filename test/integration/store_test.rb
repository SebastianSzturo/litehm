# frozen_string_literal: true

require_relative "../test_helper"

class StoreTest < Minitest::Test
  def test_run_planned_persists_and_reopens_the_authoritative_plan
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "messages-v1", connection: path) {}
      stored = LiteHM.run(plan, through: :planned)
      status = LiteHM.status("messages-v1", connection: path)

      assert_equal plan.to_h, stored.to_h
      assert_equal "planned", status.phase
      assert_equal plan.source_hash, status.source_hash
      assert_equal "resume", status.retry_action
      assert_equal "running", status.desired_state
      assert_equal 0, status.execution_revision

      reopened = LiteHM.run(plan, through: :planned)
      assert_equal stored.to_h, reopened.to_h
    end
  end

  def test_command_phase_check_is_atomic
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "command-cas", connection: path) {}
      LiteHM.run(plan, through: :planned)
      connection = LiteHM::Connection.open(path)
      store = LiteHM::Store.new(connection)

      assert_raises(LiteHM::OperationConflict) do
        store.command(plan.id, :paused, phases: %w[ready])
      end
      assert_equal "running", store.status(plan.id).desired_state
    ensure
      connection&.close
    end
  end

  def test_failure_cannot_overwrite_a_concurrent_operator_command
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "failure-command-cas", connection: path) {}
      LiteHM.run(plan, through: :planned)
      connection = LiteHM::Connection.open(path)
      store = LiteHM::Store.new(connection)
      store.command(plan.id, :abort_requested, phases: %w[planned])

      store.fail(plan.id, LiteHM::ValidationFailed.new("late failure"), pause: true)

      failed = store.status(plan.id)
      assert_equal "abort_requested", failed.desired_state
      assert_equal "late failure", failed.error.fetch("message")
    ensure
      connection&.close
    end
  end

  def test_status_is_observational_when_control_schema_is_absent
    with_database do |path|
      before = schema_snapshot(path)
      status = LiteHM.status("unknown", connection: path)

      assert status.missing?
      assert_equal before, schema_snapshot(path)
    end
  end

  def test_reusing_id_with_changed_intent_is_rejected
    with_database do |path|
      original = LiteHM.plan(:messages, id: "messages-v1", connection: path) {}
      LiteHM.run(original, through: :planned)

      changed = original.to_h
      changed_intent = { "operations" => [["different"]], "hash" => "different" }
      changed[:intent] = changed_intent
      candidate = LiteHM::Plan.new(**changed)

      error = assert_raises(LiteHM::PlanConflict) do
        LiteHM.run(candidate, through: :planned)
      end
      assert_equal "messages-v1", error.details.fetch(:plan_id)
    end
  end

  def test_only_one_pre_cutover_plan_can_own_a_table
    with_database do |path|
      first = LiteHM.plan(:messages, id: "messages-v1", connection: path) {}
      second = LiteHM.plan(:messages, id: "messages-v2", connection: path) {}
      LiteHM.run(first, through: :planned)

      assert_raises(LiteHM::OperationConflict) do
        LiteHM.run(second, through: :planned)
      end
    end
  end
end
