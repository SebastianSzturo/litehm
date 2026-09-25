# frozen_string_literal: true

require_relative "../test_helper"

class CutoverBudgetTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_hold_budget_rolls_back_cutover_and_keeps_preparation_resumable
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "hold-budget", connection: path,
        # Exercise rollback at the normal budget; recovery must not depend on
        # every filesystem completing the entire cutover within one millisecond.
        policy: { cutover_hold_ms: 50, max_cutover_attempts: 2,
          max_cutover_elapsed_ms: 1_000 }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        sleep 0.075 if point == :before_cutover_commit
      end

      error = assert_raises(LiteHM::CutoverTimeout) { LiteHM.run(plan) }
      assert_equal 2, error.details.fetch(:attempts)
      assert_equal "ready", LiteHM.status(plan.id, connection: path).phase
      assert_equal %w[id body sent_at metadata], columns(path)

      LiteHM::Testing.reset!
      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      assert_equal %w[id body sent_at metadata flag], columns(path)
    end
  end

  def test_busy_cutover_retries_after_long_application_writer
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "busy-cutover", connection: path,
        policy: { cutover_acquire_ms: 10, max_cutover_attempts: 20,
          max_cutover_elapsed_ms: 2_000 }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      ready = LiteHM.run(plan, through: :ready)
      assert ready.ready?

      writer = nil
      injected = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_cutover_acquire && !injected

        injected = true
        locked = Queue.new
        writer = Thread.new do
          database = SQLite3::Database.new(path)
          database.execute("BEGIN IMMEDIATE")
          database.execute("UPDATE messages SET sent_at = 77 WHERE id = 1")
          locked << true
          sleep 0.08
          database.execute("COMMIT")
        ensure
          database&.close
        end
        locked.pop
      end
      receipt = LiteHM.run(plan)
      writer.join

      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal 77, database.get_first_value("SELECT sent_at FROM messages WHERE id = 1")
    ensure
      writer&.join(1)
      database&.close
    end
  end

  private

  def columns(path)
    database = SQLite3::Database.new(path)
    database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
  ensure
    database&.close
  end
end
