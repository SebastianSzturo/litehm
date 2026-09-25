# frozen_string_literal: true

require_relative "../test_helper"

class WriteBudgetUnitTest < Minitest::Test
  def test_feedback_shrinks_batches_and_leaves_time_for_other_writers
    budget = LiteHM::WriteBudget.new(LiteHM::Policy.new.to_h.transform_keys(&:to_s))
    budget.observe(16, 80)
    assert_equal 1, budget.row_limit
    assert_in_delta 0.24, budget.pause_seconds(80)
    budget.observe(1, 0.1)
    assert_equal 2, budget.row_limit
    assert_operator budget.pause_seconds(0.1), :>=, 0.01
  end

  def test_invalid_latency_policies_are_rejected
    [0, -1, 0.75, Float::NAN, Float::INFINITY, "0.2"].each do |duty|
      assert_raises(ArgumentError) { LiteHM::Policy.new(writer_duty_cycle: duty) }
    end
    assert_raises(ArgumentError) { LiteHM::Policy.new(max_row_bytes: 0) }
    assert_raises(ArgumentError) { LiteHM::Policy.new(max_batch_bytes: 0) }
  end
end
