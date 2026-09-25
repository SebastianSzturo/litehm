# frozen_string_literal: true

require_relative "../test_helper"

class FaultResumeTest < Minitest::Test
  InjectedFailure = Class.new(StandardError)

  def teardown
    LiteHM::Testing.reset!
  end

  def test_resumes_after_committed_copy_batch
    with_database do |path|
      fill(path, 700)
      plan = LiteHM.plan(:messages, id: "copy-fault", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      failed = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_copy_batch_commit && !failed

        failed = true
        raise InjectedFailure
      end

      assert_raises(InjectedFailure) { LiteHM.run(plan) }
      status = LiteHM.status(plan.id, connection: path)
      assert_equal "preparing", status.phase
      assert_operator status.progress.fetch("copied_rows"), :>, 0

      LiteHM::Testing.reset!
      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      assert_equal 702, row_count(path, "messages")
    end
  end

  def test_failure_before_cutover_commit_rolls_back_and_resumes
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "cutover-rollback", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        raise InjectedFailure if point == :before_cutover_commit
      end

      assert_raises(InjectedFailure) { LiteHM.run(plan) }
      assert_equal %w[id body sent_at metadata], columns(path, "messages")
      assert_equal "ready", LiteHM.status(plan.id, connection: path).phase

      LiteHM::Testing.reset!
      assert LiteHM.run(plan).cut_over?
    end
  end

  def test_failure_after_cutover_commit_returns_receipt_on_retry
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "cutover-crash", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        raise InjectedFailure if point == :after_cutover_commit
      end

      assert_raises(InjectedFailure) { LiteHM.run(plan) }
      assert_equal "cut_over", LiteHM.status(plan.id, connection: path).phase

      LiteHM::Testing.reset!
      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      assert_equal %w[id body sent_at metadata flag], columns(path, "messages")
    end
  end

  def test_abort_resumes_bounded_artifact_drain
    with_database do |path|
      fill(path, 700)
      plan = LiteHM.plan(:messages, id: "abort-drain", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      assert LiteHM.run(plan, through: :ready).ready?
      failed = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_artifact_cleanup_batch && !failed

        failed = true
        raise InjectedFailure
      end

      assert_raises(InjectedFailure) { LiteHM.abort(plan.id, connection: path) }
      assert_equal "aborting", LiteHM.status(plan.id, connection: path).phase
      LiteHM::Testing.reset!
      assert_equal "aborted", LiteHM.abort(plan.id, connection: path).phase
      assert_equal 702, row_count(path, "messages")
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  private

  def fill(path, count)
    database = SQLite3::Database.new(path)
    database.transaction do
      count.times { |index| database.execute("INSERT INTO messages(body) VALUES (?)", ["row-#{index}"]) }
    end
  ensure
    database&.close
  end

  def row_count(path, table)
    database = SQLite3::Database.new(path)
    database.get_first_value("SELECT COUNT(*) FROM #{LiteHM::SQL.identifier(table)}")
  ensure
    database&.close
  end

  def columns(path, table)
    database = SQLite3::Database.new(path)
    database.execute("PRAGMA table_xinfo(#{LiteHM::SQL.literal(table)})").map { |row| row[1] }
  ensure
    database&.close
  end
end
