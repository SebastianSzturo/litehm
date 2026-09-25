# frozen_string_literal: true

require_relative "../test_helper"

class KeyChangeTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_primary_key_value_and_type_change_uses_durable_correspondence
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "key-change", connection: path,
        adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name} (
            code TEXT PRIMARY KEY NOT NULL,
            body TEXT NOT NULL,
            sent_at INTEGER,
            metadata BLOB
          ) WITHOUT ROWID;
        SQL
        table.project :code, "printf('message-%06d', id)"
      end
      assert LiteHM.run(plan, through: :ready).ready?

      database = SQLite3::Database.new(path)
      database.execute("UPDATE messages SET id = 20, body = 'moved' WHERE id = 1")
      database.execute("DELETE FROM messages WHERE id = 2")
      database.execute("INSERT INTO messages(id, body) VALUES (30, 'new')")
      database.close

      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal [["message-000020", "moved"], ["message-000030", "new"]],
        database.execute("SELECT code, body FROM messages ORDER BY code")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
      refute database.execute(
        "SELECT name FROM sqlite_schema WHERE name LIKE '__litehm_correspondence_%' OR name LIKE '__litehm_allocator_%'"
      ).any?
    ensure
      database&.close
    end
  end

  def test_final_tail_rejects_two_source_rows_mapping_to_one_target_key
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "key-collision", connection: path,
        adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(
            code TEXT PRIMARY KEY NOT NULL,
            body TEXT NOT NULL,
            sent_at INTEGER,
            metadata BLOB
          ) WITHOUT ROWID;
        SQL
        table.project :code,
          "CASE WHEN id = 3 THEN 'message-000001' ELSE printf('message-%06d', id) END"
      end
      assert LiteHM.run(plan, through: :ready).ready?
      inserted = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_cutover_acquire && !inserted

        inserted = true
        database = SQLite3::Database.new(path)
        database.execute("INSERT INTO messages(id, body) VALUES (3, 'collision')")
        database.close
      end

      assert_raises(LiteHM::DataIncompatible) { LiteHM.run(plan) }
      database = SQLite3::Database.new(path)
      assert_equal 3, database.get_first_value("SELECT COUNT(*) FROM messages")
      assert_equal %w[id body sent_at metadata],
        database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
      database.execute("DELETE FROM messages WHERE id = 3")
      database.close

      LiteHM::Testing.reset!
      assert LiteHM.run(plan).cut_over?
      database = SQLite3::Database.new(path)
      assert_equal 2, database.get_first_value("SELECT COUNT(*) FROM messages")
    ensure
      database&.close
    end
  end

  def test_composite_key_can_be_renamed_and_reordered_without_correspondence_loss
    Dir.mktmpdir("litehm-key-order") do |directory|
      path = File.join(directory, "keys.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE pairs(a TEXT NOT NULL, b BLOB NOT NULL, value TEXT,
          PRIMARY KEY(a, b)) WITHOUT ROWID;
        INSERT INTO pairs VALUES ('x', X'01', 'one'), ('y', X'02', 'two');
      SQL
      database.close
      plan = LiteHM.plan(:pairs, id: "key-reorder", connection: path, adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(second BLOB NOT NULL, first TEXT NOT NULL, value TEXT,
            PRIMARY KEY(second, first)) WITHOUT ROWID;
        SQL
        table.project :second, "b"
        table.project :first, "a"
      end

      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal [["\x01".b, "x", "one"], ["\x02".b, "y", "two"]],
        database.execute("SELECT second, first, value FROM pairs ORDER BY second")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end
end
