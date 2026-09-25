# frozen_string_literal: true

require_relative "../test_helper"

class ResourceBudgetTest < Minitest::Test
  def test_wal_budget_stops_after_a_committed_resumable_boundary
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "wal-budget", connection: path,
        policy: { max_wal_bytes: 1 }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      error = assert_raises(LiteHM::WalBudgetExceeded) { LiteHM.run(plan) }
      assert_operator error.details.fetch(:wal_bytes), :>, 1
      assert_equal "preparing", LiteHM.status(plan.id, connection: path).phase
      assert_equal %w[id body sent_at metadata], columns(path)
      assert_equal "aborted", LiteHM.abort(plan.id, connection: path).phase
    end
  end

  def test_total_database_artifact_budget_fails_closed
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "disk-budget", connection: path,
        policy: { max_database_bytes: 1 }) do |table|
        table.add_column :flag, :integer
      end

      error = assert_raises(LiteHM::DiskBudgetExceeded) { LiteHM.run(plan) }
      assert_operator error.details.fetch(:total_bytes), :>, 1
      assert_equal %w[id body sent_at metadata], columns(path)
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
