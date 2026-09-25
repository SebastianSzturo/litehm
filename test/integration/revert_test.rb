# frozen_string_literal: true

require_relative "../test_helper"

class RevertTest < Minitest::Test
  def test_revert_is_a_second_online_migration_and_preserves_post_cutover_writes
    with_database do |path|
      forward = LiteHM.change_table(:messages, id: "messages-forward", connection: path) do |table|
        table.rename_column :body, :content
        table.add_column :flag, :integer, null: false, default: 0
      end
      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO messages(content, sent_at, metadata, flag) VALUES (?, ?, ?, ?)",
        ["after cutover", 99, "new".b, 7])
      database.close

      reverse = LiteHM.revert(forward, connection: path)

      assert reverse.cut_over?
      assert_equal "revert_messages-forward", reverse.plan_id
      database = SQLite3::Database.new(path)
      assert_equal %w[id body sent_at metadata],
        database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
      assert_equal ["after cutover", 99, "new".b],
        database.get_first_row("SELECT body, sent_at, metadata FROM messages WHERE id = 3")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_revert_inherits_forward_policy_so_outbound_foreign_keys_can_revert
    Dir.mktmpdir("litehm-test") do |directory|
      path = File.join(directory, "test.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE parents(id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE children(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id), value TEXT);
        CREATE INDEX children_parent ON children(parent_id);
        INSERT INTO parents VALUES (1, 'a'), (2, 'b');
        INSERT INTO children VALUES (1, 1, 'v1'), (2, 2, 'v2');
      SQL
      database.close

      forward = LiteHM.change_table(:children, id: "children-forward", connection: path,
        policy: { archive: :ephemeral, cutover_hold_ms: 75 }) do |table|
        table.add_index :value
      end
      assert forward.cut_over?

      reverse = LiteHM.revert("children-forward", connection: path)
      assert reverse.cut_over?
      policy = LiteHM.with_open_connection(path) do |opened|
        LiteHM::Store.new(opened).plan(reverse.plan_id).policy
      end
      assert_equal "ephemeral", policy.fetch("archive")
      assert_equal 75, policy.fetch("cutover_hold_ms")

      database = SQLite3::Database.new(path)
      refute database.get_first_value(
        "SELECT 1 FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'children' AND sql LIKE '%value%'"
      )
      assert_equal [], database.execute("PRAGMA foreign_key_check")
    ensure
      database&.close
    end
  end

  def test_revert_policy_overrides_win_over_the_inherited_policy
    with_database do |path|
      forward = LiteHM.change_table(:messages, id: "override-forward", connection: path,
        policy: { cutover_hold_ms: 75 }) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      reverse = LiteHM.revert(forward, connection: path, policy: { cutover_hold_ms: 90 })
      assert reverse.cut_over?
      policy = LiteHM.with_open_connection(path) do |opened|
        LiteHM::Store.new(opened).plan(reverse.plan_id).policy
      end
      assert_equal 90, policy.fetch("cutover_hold_ms")
    end
  end

  def test_lossy_forward_change_requires_explicit_reverse_projection
    with_database do |path|
      forward = LiteHM.change_table(:messages, id: "drop-metadata", connection: path) do |table|
        table.remove_column :metadata
      end

      error = assert_raises(LiteHM::ReverseProjectionRequired) do
        LiteHM.revert(forward, connection: path)
      end
      assert_equal "metadata", error.details.fetch(:column)

      reverse = LiteHM.revert(forward, connection: path) do |table|
        table.project :metadata, "NULL"
      end
      assert reverse.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal 2, database.get_first_value("SELECT COUNT(*) FROM messages WHERE metadata IS NULL")
    ensure
      database&.close
    end
  end

  def test_revert_never_renames_stale_archive_back
    with_database do |path|
      forward = LiteHM.change_table(:messages, id: "archive-proof", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      database = SQLite3::Database.new(path)
      database.execute("UPDATE messages SET body = 'new live value' WHERE id = 1")
      database.close

      LiteHM.revert(forward, connection: path)
      database = SQLite3::Database.new(path)
      assert_equal "new live value", database.get_first_value("SELECT body FROM messages WHERE id = 1")
      assert_equal "hello", database.get_first_value(
        "SELECT body FROM #{LiteHM::SQL.identifier(forward.archive_name)} WHERE id = 1"
      )
    ensure
      database&.close
    end
  end

  def test_revert_refuses_a_receipt_after_a_later_schema_change
    with_database do |path|
      forward = LiteHM.change_table(:messages, id: "stale-forward", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      LiteHM.change_table(:messages, id: "later-change", connection: path) do |table|
        table.add_column :later_value, :text
      end

      error = assert_raises(LiteHM::SchemaDrift) do
        LiteHM.revert(forward, connection: path)
      end
      assert_equal forward.target_hash, error.details.fetch(:expected_hash)
      database = SQLite3::Database.new(path)
      assert_includes database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }, "later_value"
      assert_equal "missing", LiteHM.status("revert_stale-forward", connection: path).phase
    ensure
      database&.close
    end
  end

  def test_revert_applies_busy_timeout_before_registering_reverse_plan
    with_database do |path|
      forward = LiteHM.change_table(:messages, id: "busy-revert-forward", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      reader, writer_signal = IO.pipe
      writer_pid = fork do
        reader.close
        database = SQLite3::Database.new(path)
        database.execute("BEGIN IMMEDIATE")
        writer_signal.write("1")
        writer_signal.close
        sleep 0.08
        database.execute("COMMIT")
        database&.close
        exit! 0
      end
      writer_signal.close
      reader.read(1)
      reader.close

      reverse = LiteHM.revert(forward, connection: path,
        policy: { busy_timeout_ms: 1_000 })
      assert reverse.cut_over?
      Process.wait(writer_pid)
    ensure
      begin
        Process.wait(writer_pid) if writer_pid
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
