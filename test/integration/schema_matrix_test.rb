# frozen_string_literal: true

require_relative "../test_helper"

class SchemaMatrixTest < Minitest::Test
  def test_combined_active_record_rebuild_operations_and_null_backfill
    with_database do |path|
      receipt = LiteHM.change_table(:messages, id: "ar-schema-matrix", connection: path) do |table|
        table.change_column :sent_at, :string, default: "unknown"
        table.change_column_default :body, from: nil, to: "empty"
        table.change_column_null :metadata, false, "fallback".b
        table.add_check_constraint "length(body) > 0", name: :body_present
        table.add_timestamps null: true
      end
      assert receipt.cut_over?

      database = SQLite3::Database.new(path)
      columns = database.execute("PRAGMA table_xinfo(messages)")
      assert_equal %w[id body sent_at metadata created_at updated_at], columns.map { |row| row[1] }
      assert_equal %w[TEXT TEXT], columns.values_at(1, 2).map { |row| row[2].upcase }
      assert_match(/STRICT\z/, database.get_first_value(
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'messages'"
      ))
      assert_equal ["\x00\xff".b, "fallback".b],
        database.execute("SELECT metadata FROM messages ORDER BY id").flatten
      assert_raises(SQLite3::ConstraintException) do
        database.execute("INSERT INTO messages(body, metadata) VALUES ('', X'01')")
      end
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_raw_exact_target_supports_strict_generated_check_partial_expression_and_descending_indexes
    with_database do |path|
      receipt = LiteHM.change_table(:messages, id: "raw-schema-matrix", connection: path,
        adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name} (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            body TEXT NOT NULL CHECK(length(body) > 0),
            sent_at INTEGER,
            metadata BLOB,
            body_length INTEGER GENERATED ALWAYS AS (length(body)) STORED
          ) STRICT;
          CREATE INDEX messages_recent_body ON #{table.name}
            (sent_at DESC, lower(body) COLLATE NOCASE)
            WHERE sent_at IS NOT NULL;
        SQL
      end
      assert receipt.cut_over?

      database = SQLite3::Database.new(path)
      assert_equal [[1, 5], [2, 5]],
        database.execute("SELECT id, body_length FROM messages ORDER BY id")
      table_sql = database.get_first_value("SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'messages'")
      assert_match(/GENERATED ALWAYS/, table_sql)
      assert_match(/STRICT\z/, table_sql)
      index = database.get_first_row("PRAGMA index_list(messages)")
      assert_equal 1, index[4]
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end
end
