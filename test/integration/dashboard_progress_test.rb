# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/helpers/litehm/operation_summary"

# The data the engine derives its progress and plan summary from.
class DashboardProgressTest < Minitest::Test
  def test_prepare_records_the_copy_key_range_and_status_carries_the_plan
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "dashboard-progress", connection: path) do |table|
        table.add_index :sent_at, name: :messages_sent_at_dashboard
      end
      LiteHM.run(plan, through: :ready, connection: path)

      ready = LiteHM.status(plan.id, connection: path)
      assert_equal [{ "type" => "integer", "value" => 1 }], ready.progress.fetch("copy_lower_bound")
      assert_equal [{ "type" => "integer", "value" => 2 }], ready.progress.fetch("copy_upper_bound")
      assert_equal [["add_index", ["sent_at"], { "name" => "messages_sent_at_dashboard" }]], ready.intent
      assert_equal "automatic", ready.policy.fetch("cutover")

      summary = LiteHM::OperationSummary.new(ready)
      assert_equal 3, summary.step
      assert_equal 100, summary.percent
      assert_equal 2, summary.total_rows

      LiteHM.run(plan, connection: path)
      cut_over = LiteHM.status(plan.id, connection: path)
      refute_nil cut_over.cutover_at
      assert_equal :live_archive, LiteHM::OperationSummary.new(cut_over).state
    end
  end

  def test_runner_reads_skip_the_plan_summary
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "dashboard-hot-path", connection: path) { |table| table.add_index :body, name: :messages_body_dashboard }
      LiteHM.run(plan, through: :planned, connection: path)
      LiteHM::Connection.open(path).then do |connection|
        status = LiteHM::Store.new(connection).status(plan.id)
        assert_nil status.intent
        assert_nil status.policy
      ensure
        connection.close
      end
    end
  end
end
