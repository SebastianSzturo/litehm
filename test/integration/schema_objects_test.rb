# frozen_string_literal: true

require_relative "../test_helper"

class SchemaObjectsTest < Minitest::Test
  def test_trigger_and_view_are_rewritten_for_renamed_column
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        CREATE TABLE message_audit(message_id INTEGER, observed_body TEXT);
        CREATE TRIGGER audit_message_update AFTER UPDATE OF body ON messages
        BEGIN
          INSERT INTO message_audit VALUES (NEW.id, NEW.body);
        END;
        CREATE VIEW message_bodies AS SELECT id, body FROM messages;
      SQL
      database.close

      receipt = LiteHM.change_table(:messages, id: "objects-rename", connection: path) do |table|
        table.rename_column :body, :content
      end
      assert receipt.cut_over?

      database = SQLite3::Database.new(path)
      database.execute("UPDATE messages SET content = 'updated' WHERE id = 1")
      assert_equal [[1, "updated"]], database.execute("SELECT * FROM message_audit")
      assert_equal [1, "updated"], database.get_first_row("SELECT * FROM message_bodies WHERE id = 1")
      trigger_sql = database.get_first_value("SELECT sql FROM sqlite_schema WHERE name = 'audit_message_update'")
      view_sql = database.get_first_value("SELECT sql FROM sqlite_schema WHERE name = 'message_bodies'")
      assert_match(/content/, trigger_sql)
      assert_match(/content/, view_sql)
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_trigger_on_another_table_that_writes_source_is_rejected
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        CREATE TABLE inbox(payload TEXT NOT NULL);
        CREATE TRIGGER import_inbox AFTER INSERT ON inbox
        BEGIN
          INSERT INTO messages(body) VALUES (NEW.payload);
        END;
      SQL
      database.close

      plan = LiteHM.plan(:messages, id: "external-trigger", connection: path) do |table|
        table.rename_column :body, :content
      end
      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_equal ["import_inbox"], error.details.fetch(:triggers)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    ensure
      database&.close
    end
  end

  def test_dependent_view_must_compile_against_target
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("CREATE VIEW message_bodies AS SELECT id, body FROM messages")
      database.close

      error = assert_raises(LiteHM::InvalidPlan) do
        LiteHM.plan(:messages, id: "stale-view", connection: path) do |table|
          table.remove_column :body
        end
      end
      assert_match(/dependent view/, error.message)
      database = SQLite3::Database.new(path)
      assert_equal [[1, "hello"], [2, "world"]], database.execute("SELECT * FROM message_bodies")
    ensure
      database&.close
    end
  end
end
