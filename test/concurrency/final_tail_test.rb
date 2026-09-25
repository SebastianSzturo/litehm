# frozen_string_literal: true

require_relative "../test_helper"

class FinalTailTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_ready_defers_a_large_final_tail_to_bounded_reconciliation
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "ready-large-tail", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      inserted = false
      deferred = []
      folded = []
      LiteHM::Testing.fault_injector = lambda do |point, context|
        if point == :before_ready_acquire && !inserted
          inserted = true
          insert_rows(path, 300)
        elsif point == :tail_deferred
          deferred << context.fetch(:rows)
        elsif point == :dirty_fold
          folded << context.fetch(:rows)
        end
      end

      status = LiteHM.run(plan, through: :ready)

      assert status.ready?
      assert_operator deferred.max, :>, LiteHM::Runner::BATCH_ROWS
      assert_operator folded.max, :<=, LiteHM::Runner::BATCH_ROWS
      assert_equal 302, row_count(path)
    end
  end

  def test_cutover_defers_a_large_final_tail_to_bounded_reconciliation
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "cutover-large-tail", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      assert LiteHM.run(plan, through: :ready).ready?
      inserted = false
      deferred = []
      LiteHM::Testing.fault_injector = lambda do |point, context|
        if point == :before_cutover_acquire && !inserted
          inserted = true
          insert_rows(path, 300)
        elsif point == :tail_deferred
          deferred << context.fetch(:rows)
        end
      end

      receipt = LiteHM.run(plan)

      assert receipt.cut_over?
      assert_operator deferred.max, :>, LiteHM::Runner::BATCH_ROWS
      assert_equal 302, row_count(path)
    end
  end

  def test_ready_stops_after_configured_retry_budget_without_rescanning
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "ready-budget", connection: path,
        policy: { writer_lease_ms: 1, cutover_hold_ms: 1, max_ready_batches: 2,
          max_cutover_elapsed_ms: 10_000 }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      inserted = false
      validation_scans = 0
      LiteHM::Testing.fault_injector = lambda do |point, context|
        if point == :before_ready_acquire && !inserted
          inserted = true
          insert_rows(path, 1)
        elsif point == :before_validate_all_ranges
          validation_scans += 1
        elsif point == :before_final_validation && context.fetch(:target_identities).any?
          sleep 0.01
        end
      end

      error = assert_raises(LiteHM::BusyBudgetExceeded) do
        LiteHM.run(plan, through: :ready)
      end
      assert_equal 2, error.details.fetch(:attempts)
      assert_equal 1, validation_scans
      assert_equal "preparing", LiteHM.status(plan.id, connection: path).phase

      LiteHM::Testing.reset!
      assert LiteHM.run(plan, through: :ready).ready?
    end
  end

  private

  def insert_rows(path, count)
    database = SQLite3::Database.new(path)
    database.transaction do
      count.times do |index|
        database.execute("INSERT INTO messages(body, sent_at) VALUES (?, ?)",
          ["tail-#{index}", 10_000 + index])
      end
    end
  ensure
    database&.close
  end

  def row_count(path)
    database = SQLite3::Database.new(path)
    database.get_first_value("SELECT COUNT(*) FROM messages")
  ensure
    database&.close
  end
end
