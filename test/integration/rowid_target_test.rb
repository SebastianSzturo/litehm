# frozen_string_literal: true

require_relative "../test_helper"

class RowidTargetTest < Minitest::Test
  def test_integer_primary_key_can_be_removed_into_deterministic_hidden_rowids
    with_database do |path|
      receipt = LiteHM.change_table(:messages, id: "remove-key", connection: path,
        adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name} (body TEXT NOT NULL, sent_at INTEGER, metadata BLOB);
        SQL
      end
      assert receipt.cut_over?

      database = SQLite3::Database.new(path)
      assert_equal [[1, "hello"], [2, "world"]],
        database.execute("SELECT rowid, body FROM messages ORDER BY rowid")
      database.execute("INSERT INTO messages(body) VALUES ('after')")
      assert_equal 3, database.get_first_value("SELECT rowid FROM messages WHERE body = 'after'")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_composite_source_to_unkeyed_target_uses_durable_rowid_allocator
    Dir.mktmpdir("litehm-unkeyed") do |directory|
      path = File.join(directory, "unkeyed.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE items(a TEXT NOT NULL, b TEXT NOT NULL, value TEXT,
          PRIMARY KEY(a, b)) WITHOUT ROWID;
        INSERT INTO items VALUES ('one', 'a', 'first'), ('two', 'b', 'second');
      SQL
      database.close
      plan = LiteHM.plan(:items, connection: path, adapter: :raw) do |table|
        table.ddl "DROP TABLE #{table.name}; CREATE TABLE #{table.name}(value TEXT)"
      end

      assert LiteHM.run(plan, through: :ready).ready?
      database = SQLite3::Database.new(path)
      database.execute("UPDATE items SET a = 'moved' WHERE a = 'one'")
      database.execute("DELETE FROM items WHERE a = 'two'")
      database.execute("INSERT INTO items VALUES ('three', 'c', 'third')")
      database.close

      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal [[3, "first"], [4, "third"]],
        database.execute("SELECT rowid, value FROM items ORDER BY rowid")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_allocator_validation_keeps_pending_source_rows_aligned
    Dir.mktmpdir("litehm-unkeyed-pending") do |directory|
      path = File.join(directory, "pending.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE items(a TEXT NOT NULL, b TEXT NOT NULL, value TEXT,
          PRIMARY KEY(a, b)) WITHOUT ROWID;
        INSERT INTO items VALUES ('one', 'a', 'first'), ('two', 'b', 'second');
      SQL
      database.close
      plan = LiteHM.plan(:items, id: "pending-allocator", connection: path, adapter: :raw) do |table|
        table.ddl "DROP TABLE #{table.name}; CREATE TABLE #{table.name}(value TEXT)"
      end
      inserted = false
      writer = nil
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_validate_all_ranges && !inserted

        inserted = true
        writer = SQLite3::Database.new(path)
        writer.execute("INSERT INTO items VALUES ('middle', 'c', 'pending')")
        writer.close
      end

      assert LiteHM.run(plan).cut_over?
      database = SQLite3::Database.new(path)
      assert_equal %w[first pending second],
        database.execute("SELECT value FROM items ORDER BY value").flatten
    ensure
      LiteHM::Testing.reset!
      database&.close
      writer&.close
    end
  end

  def test_bare_rowid_opt_in_and_revert_preserve_live_rowids
    with_database do |path|
      forward = LiteHM.change_table(:messages, id: "rowid-revert", connection: path,
        adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(body TEXT NOT NULL, sent_at INTEGER, metadata BLOB);
        SQL
      end
      database = SQLite3::Database.new(path)
      database.execute("UPDATE messages SET body = 'after cutover' WHERE rowid = 1")
      database.execute("INSERT INTO messages(body) VALUES ('new row')")
      database.close

      reverse = LiteHM.revert(forward, connection: path,
        policy: { allow_bare_rowid: true }) do |table|
        table.project :id, "rowid"
      end
      assert reverse.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal [[1, "after cutover"], [2, "world"], [3, "new row"]],
        database.execute("SELECT id, body FROM messages ORDER BY id")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_generated_unique_column_is_not_selected_as_target_locator
    with_database do |path|
      receipt = LiteHM.change_table(:messages, id: "generated-locator", connection: path,
        adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(
            body TEXT NOT NULL,
            sent_at INTEGER,
            metadata BLOB,
            slug TEXT GENERATED ALWAYS AS (lower(body)) STORED NOT NULL UNIQUE
          );
        SQL
      end

      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal [[1, "hello"], [2, "world"]],
        database.execute("SELECT rowid, slug FROM messages ORDER BY rowid")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_integer_primary_key_desc_with_nullable_rows_is_not_treated_as_rowid_alias
    Dir.mktmpdir("litehm-pk-desc") do |directory|
      path = File.join(directory, "desc.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE items(x INTEGER PRIMARY KEY DESC, value TEXT);
        INSERT INTO items(x, value) VALUES (NULL, 'nullable');
      SQL
      database.close
      plan = LiteHM.plan(:items, id: "pk-desc", connection: path) do |table|
        table.add_column :flag, :integer
      end

      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO items(x, value) VALUES (NULL, 'still writable')")
      assert_equal 2, database.get_first_value("SELECT COUNT(*) FROM items")
    ensure
      database&.close
    end
  end
end
