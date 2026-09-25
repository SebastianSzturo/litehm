# frozen_string_literal: true

require_relative "../test_helper"

class SchemaDriftTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_schema_drift_is_rejected_inside_ready_gate
    with_database do |path|
      plan = migration_plan(path, "ready-drift")
      changed = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_ready_acquire && !changed

        changed = true
        add_live_column(path)
      end

      assert_raises(LiteHM::SchemaDrift) { LiteHM.run(plan) }
      assert_equal "preparing", LiteHM.status(plan.id, connection: path).phase
      assert_includes columns(path), "other_deploy"
    end
  end

  def test_schema_drift_is_rejected_inside_cutover_gate
    with_database do |path|
      plan = migration_plan(path, "cutover-drift")
      assert LiteHM.run(plan, through: :ready).ready?
      changed = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_cutover_acquire && !changed

        changed = true
        add_live_column(path)
      end

      assert_raises(LiteHM::SchemaDrift) { LiteHM.run(plan) }
      assert_equal "ready", LiteHM.status(plan.id, connection: path).phase
      assert_includes columns(path), "other_deploy"
    end
  end

  private

  def migration_plan(path, id)
    LiteHM.plan(:messages, id:, connection: path) do |table|
      table.add_column :flag, :integer, null: false, default: 0
    end
  end

  def add_live_column(path)
    database = SQLite3::Database.new(path)
    database.execute("ALTER TABLE messages ADD COLUMN other_deploy TEXT")
  ensure
    database&.close
  end

  def columns(path)
    database = SQLite3::Database.new(path)
    database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
  ensure
    database&.close
  end
end
