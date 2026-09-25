# frozen_string_literal: true

require_relative "../test_helper"

class ReplaceUpsertTest < Minitest::Test
  def test_declared_replace_policy_requires_recursive_trigger_contract
    with_replace_database do |path|
      plan = LiteHM.plan(:items, connection: path) { |table| table.add_column :flag, :integer }

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/all_writers_recursive_triggers/, error.message)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  def test_insert_or_replace_captures_displaced_and_inserted_identities
    with_replace_database do |path|
      plan = LiteHM.plan(:items, id: "replace-capture", connection: path,
        adapter: :raw,
        policy: { source_replace_writes: true, all_writers_recursive_triggers: true }) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(
            id INTEGER PRIMARY KEY,
            code TEXT UNIQUE,
            value TEXT,
            flag INTEGER NOT NULL DEFAULT 0
          );
        SQL
      end
      assert LiteHM.run(plan, through: :ready).ready?

      writer = SQLite3::Database.new(path)
      writer.execute("PRAGMA recursive_triggers = ON")
      writer.execute("INSERT OR REPLACE INTO items(id, code, value) VALUES (3, 'same', 'replacement')")
      writer.close
      LiteHM.run(plan)

      database = SQLite3::Database.new(path)
      assert_equal [[3, "same", "replacement", 0]], database.execute("SELECT * FROM items")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      writer&.close
      database&.close
    end
  end

  def test_upsert_update_and_do_nothing_converge_to_current_source
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("CREATE UNIQUE INDEX messages_unique_body ON messages(body)")
      database.close
      plan = LiteHM.plan(:messages, id: "upsert-capture", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      LiteHM.run(plan, through: :ready)

      writer = SQLite3::Database.new(path)
      writer.execute(<<~SQL)
        INSERT INTO messages(id, body, sent_at) VALUES (9, 'hello', 50)
        ON CONFLICT(body) DO UPDATE SET sent_at = excluded.sent_at
      SQL
      writer.execute(<<~SQL)
        INSERT INTO messages(id, body, sent_at) VALUES (10, 'world', 60)
        ON CONFLICT(body) DO NOTHING
      SQL
      writer.close
      LiteHM.run(plan)

      database = SQLite3::Database.new(path)
      assert_equal [[1, "hello", 50], [2, "world", 2]],
        database.execute("SELECT id, body, sent_at FROM messages ORDER BY id")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      writer&.close
      database&.close
    end
  end

  private

  def with_replace_database
    Dir.mktmpdir("litehm-replace") do |directory|
      path = File.join(directory, "replace.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE items(
          id INTEGER PRIMARY KEY,
          code TEXT UNIQUE ON CONFLICT REPLACE,
          value TEXT
        );
        INSERT INTO items VALUES (1, 'same', 'original');
      SQL
      database.close
      yield path
    ensure
      database&.close unless database&.closed?
    end
  end
end
