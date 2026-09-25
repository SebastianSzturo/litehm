# frozen_string_literal: true

require_relative "../test_helper"

class CaptureLossTest < Minitest::Test
  def test_dropped_capture_with_uncaptured_writes_forces_full_rescan
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "capture-loss", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      assert LiteHM.run(plan, through: :ready).ready?

      database = SQLite3::Database.new(path)
      trigger = database.get_first_value(<<~SQL)
        SELECT name FROM sqlite_schema
        WHERE type = 'trigger' AND name LIKE '__litehm_capture_update_%'
      SQL
      database.execute("DROP TRIGGER #{LiteHM::SQL.identifier(trigger)}")
      database.execute("UPDATE messages SET body = 'uncaptured' WHERE id = 1")
      database.execute("DELETE FROM messages WHERE id = 2")
      database.execute("INSERT INTO messages(body) VALUES ('new uncaptured')")
      database.close

      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal [[1, "uncaptured", 0], [3, "new uncaptured", 0]],
        database.execute("SELECT id, body, flag FROM messages ORDER BY id")
      status = LiteHM.status(plan.id, connection: path)
      assert_operator status.progress.fetch("capture_repairs"), :>=, 1
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_replaced_noop_trigger_is_detected_by_schema_hash
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "capture-tamper", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      LiteHM.run(plan, through: :ready)
      database = SQLite3::Database.new(path)
      trigger = database.get_first_value(<<~SQL)
        SELECT name FROM sqlite_schema
        WHERE type = 'trigger' AND name LIKE '__litehm_capture_delete_%'
      SQL
      database.execute("DROP TRIGGER #{LiteHM::SQL.identifier(trigger)}")
      database.execute(<<~SQL)
        CREATE TRIGGER #{LiteHM::SQL.identifier(trigger)} AFTER DELETE ON messages BEGIN SELECT 1; END
      SQL
      database.execute("DELETE FROM messages WHERE id = 1")
      database.close

      LiteHM.run(plan)
      database = SQLite3::Database.new(path)
      assert_equal [[2, "world"]], database.execute("SELECT id, body FROM messages")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end
end
