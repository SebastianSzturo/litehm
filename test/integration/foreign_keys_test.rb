# frozen_string_literal: true

require_relative "../test_helper"

class ForeignKeysTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_outbound_fk_allows_parent_cascades_and_releases_ephemeral_archive
    with_foreign_key_database do |path|
      plan = LiteHM.plan(:messages, id: "outbound-fk", connection: path,
        policy: { archive: :ephemeral }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      ready = LiteHM.run(plan, through: :ready)
      assert ready.ready?

      writer = SQLite3::Database.new(path)
      writer.execute("PRAGMA foreign_keys = ON")
      writer.execute("DELETE FROM conversations WHERE id = 1")
      assert_equal 0, writer.get_first_value("SELECT COUNT(*) FROM messages")
      writer.close

      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      assert_equal "archive_released", receipt.phase
      assert_nil receipt.archive_name
      assert_equal "done", LiteHM.status(plan.id, connection: path).phase

      writer = SQLite3::Database.new(path)
      writer.execute("PRAGMA foreign_keys = ON")
      writer.execute("DELETE FROM conversations WHERE id = 1")
      assert_equal 0, writer.get_first_value("SELECT COUNT(*) FROM messages")
      assert_empty writer.execute("PRAGMA foreign_key_check")
      guards = writer.execute("SELECT name FROM sqlite_schema WHERE type = 'trigger' AND name LIKE '__litehm_guard_%'")
      assert_empty guards
    ensure
      writer&.close
    end
  end

  def test_outbound_fk_requires_ephemeral_archive_policy_before_artifacts
    with_foreign_key_database do |path|
      plan = LiteHM.plan(:messages, connection: path) { |table| table.add_column :flag, :integer }

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/archive: :ephemeral/, error.message)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  def test_abort_removes_parent_guards
    with_foreign_key_database do |path|
      plan = LiteHM.plan(:messages, id: "abort-outbound-fk", connection: path,
        policy: { archive: :ephemeral }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      assert LiteHM.run(plan, through: :ready).ready?

      assert_equal "aborted", LiteHM.abort(plan.id, connection: path).phase
      database = SQLite3::Database.new(path)
      database.execute("PRAGMA foreign_keys = ON")
      database.execute("DELETE FROM conversations WHERE id = 1")
      assert_equal 0, database.get_first_value("SELECT COUNT(*) FROM messages")
      assert_empty database.execute(
        "SELECT name FROM sqlite_schema WHERE type = 'trigger' AND name LIKE '__litehm_guard_%'"
      )
    ensure
      database&.close
    end
  end

  def test_inbound_fk_survives_when_referenced_key_is_exactly_preserved
    with_foreign_key_database do |path|
      receipt = LiteHM.change_table(:conversations, id: "inbound-fk", connection: path) do |table|
        table.add_column :subject, :text
      end
      assert receipt.cut_over?

      database = SQLite3::Database.new(path)
      database.execute("PRAGMA foreign_keys = ON")
      assert_empty database.execute("PRAGMA foreign_key_check")
      assert_raises(SQLite3::ConstraintException) do
        database.execute("INSERT INTO messages(conversation_id, body) VALUES (999, 'orphan')")
      end
    ensure
      database&.close
    end
  end

  def test_final_tail_rejects_orphan_from_writer_with_foreign_keys_disabled
    with_foreign_key_database do |path|
      plan = LiteHM.plan(:messages, id: "orphan-final-tail", connection: path,
        policy: { archive: :ephemeral }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      assert LiteHM.run(plan, through: :ready).ready?

      inserted = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_cutover_acquire && !inserted

        inserted = true
        writer = SQLite3::Database.new(path)
        writer.execute("PRAGMA foreign_keys = OFF")
        writer.execute("INSERT INTO messages VALUES (2, 999, 'orphan')")
        writer.close
      end

      assert_raises(LiteHM::ValidationFailed) { LiteHM.run(plan) }
      assert_equal "ready", LiteHM.status(plan.id, connection: path).phase
      LiteHM::Testing.reset!
      writer = SQLite3::Database.new(path)
      writer.execute("DELETE FROM messages WHERE id = 2")
      writer.close
      assert LiteHM.run(plan).cut_over?
      database = SQLite3::Database.new(path)
      assert_empty database.execute("PRAGMA foreign_key_check")
    ensure
      writer&.close
      database&.close
    end
  end

  def test_inbound_fk_refuses_referenced_key_rename
    with_foreign_key_database do |path|
      plan = LiteHM.plan(:conversations, connection: path) { |table| table.rename_column :id, :conversation_id }

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_equal "messages", error.details.fetch(:child_table)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  def test_inbound_fk_refuses_target_that_removes_parent_uniqueness
    with_foreign_key_database do |path|
      plan = LiteHM.plan(:conversations, connection: path, adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(
            code INTEGER PRIMARY KEY,
            id INTEGER NOT NULL,
            title TEXT
          );
        SQL
        table.project :code, "id"
      end

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/exact, unique, and collation-compatible/, error.message)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  def test_inbound_fk_refuses_referenced_unique_key_collation_change
    with_collated_foreign_key_database do |path|
      plan = LiteHM.plan(:parents, connection: path, adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(
            id INTEGER PRIMARY KEY,
            code TEXT NOT NULL COLLATE BINARY UNIQUE,
            value TEXT
          );
        SQL
      end

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/collation-compatible/, error.message)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  private

  def with_foreign_key_database
    Dir.mktmpdir("litehm-fk") do |directory|
      path = File.join(directory, "foreign.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE conversations(id INTEGER PRIMARY KEY, title TEXT);
        CREATE TABLE messages(
          id INTEGER PRIMARY KEY,
          conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          body TEXT NOT NULL
        );
        CREATE INDEX messages_parent ON messages(conversation_id);
        INSERT INTO conversations VALUES (1, 'one');
        INSERT INTO messages VALUES (1, 1, 'hello');
      SQL
      database.close
      yield path
    ensure
      database&.close unless database&.closed?
    end
  end

  def with_collated_foreign_key_database
    Dir.mktmpdir("litehm-collated-fk") do |directory|
      path = File.join(directory, "collated.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE parents(
          id INTEGER PRIMARY KEY,
          code TEXT NOT NULL COLLATE NOCASE UNIQUE,
          value TEXT
        );
        CREATE TABLE children(
          id INTEGER PRIMARY KEY,
          parent_code TEXT REFERENCES parents(code)
        );
        INSERT INTO parents VALUES (1, 'Alpha', 'one');
        INSERT INTO children VALUES (1, 'alpha');
      SQL
      database.close
      yield path
    ensure
      database&.close unless database&.closed?
    end
  end
end
