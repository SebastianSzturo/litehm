# frozen_string_literal: true

require_relative "../test_helper"

class TelemetrySummaryTest < Minitest::Test
  def test_summary_is_bounded_and_counts_only_committed_row_visits
    plan = Struct.new(:id, :table).new("summary-test", "messages")
    time = 0.0
    telemetry = LiteHM::Telemetry.new(plan, clock: -> { time })
    telemetry.stage = :copy
    assert telemetry.snapshot_due?
    telemetry.saved!
    time = 4.0
    refute telemetry.snapshot_due?
    100.times do
      telemetry.batch(kind: :copy, rows: 16, transaction_ms: 1.0, lock_wait_ms: 0.1,
        committed: true, previous_rows: 16, next_rows: 16, pause_ms: 10)
    end
    telemetry.batch(kind: :copy, rows: 16, transaction_ms: 2.0, lock_wait_ms: 0.1,
      committed: false, previous_rows: 16, next_rows: 8, pause_ms: 10)
    time = 5.0
    assert telemetry.snapshot_due?
    telemetry.checkpoint(result: [0, 12, 3], elapsed_ms: 2.0)
    snapshot = telemetry.snapshot
    assert_equal 1_600, snapshot.dig("stages", "copy", "rows")
    assert_equal 320.0, snapshot.dig("stages", "copy", "rows_per_second")
    assert_equal 1, snapshot["rollbacks"]
    assert_equal 9, snapshot.dig("checkpoint", "pending_frames")
    assert_operator JSON.generate(snapshot).bytesize, :<, 2_048
    telemetry.checkpoint(result: [0, -1, -1], elapsed_ms: 0.1)
    assert_nil telemetry.snapshot.dig("checkpoint", "pending_frames")
    assert_equal "unavailable", telemetry.snapshot.dig("checkpoint", "status")
  end
end
