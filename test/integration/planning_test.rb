# frozen_string_literal: true

require_relative "../test_helper"

class PlanningTest < Minitest::Test
  def test_plan_is_observational_and_stable
    with_database do |path|
      before = schema_snapshot(path)
      first = LiteHM.plan(:messages, connection: path) {}
      second = LiteHM.plan(:messages, connection: path) {}

      assert_equal before, schema_snapshot(path)
      assert_equal first.id, second.id
      assert_equal first.to_h, second.to_h
      assert first.frozen?
      assert first.source_manifest.frozen?
      assert_equal "messages", first.table
      assert_equal first.source_hash, first.target_hash
    end
  end

  def test_explicit_id_and_binary_schema_are_supported
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "body-index-v1", connection: path) {}

      assert_equal "body-index-v1", plan.id
      assert_equal %w[id body sent_at metadata], plan.projection.keys
      assert_equal "sqlite3", plan.adapter
    end
  end

  def test_missing_table_is_rejected_without_creating_control_tables
    with_database do |path|
      error = assert_raises(LiteHM::InvalidPlan) do
        LiteHM.plan(:missing, connection: path) {}
      end

      assert_match(/does not exist/, error.message)
      refute schema_snapshot(path).flatten.include?("litehm_plans")
    end
  end
end
