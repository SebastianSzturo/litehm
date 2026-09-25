# frozen_string_literal: true

require_relative "../test_helper"

class RunnerTest < Minitest::Test
  def test_change_table_copies_data_and_cuts_over_automatically
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO messages(body, sent_at) VALUES (?, ?)", ["later", 3])
      database.close

      receipt = LiteHM.change_table(:messages, id: "messages-delivered", connection: path) do |table|
        table.rename_column :body, :content
        table.remove_column :metadata
        table.add_column :delivered, :boolean, null: false, default: false
        table.add_index %i[delivered sent_at], name: :messages_delivery
      end

      assert receipt.cut_over?
      assert_equal "messages-delivered", receipt.plan_id
      assert_equal "converged", receipt.capture_state
      assert_match(/__litehm_archive_/, receipt.archive_name)

      database = SQLite3::Database.new(path)
      columns = database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
      rows = database.execute("SELECT id, content, sent_at, delivered FROM messages ORDER BY id")
      assert_equal %w[id content sent_at delivered], columns
      assert_equal [[1, "hello", 1, 0], [2, "world", 2, 0], [3, "later", 3, 0]], rows
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
      assert_empty database.execute("PRAGMA foreign_key_check")

      index_map = database.get_first_row(<<~SQL)
        SELECT logical_name, physical_name FROM litehm_index_names
        WHERE table_name = 'messages' AND logical_name = 'messages_delivery'
      SQL
      assert_equal "messages_delivery", index_map[0]
      assert_match(/__litehm_index_/, index_map[1])
    ensure
      database&.close
    end
  end

  def test_identical_retry_returns_durable_receipt
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "messages-retry", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      first = LiteHM.run(plan)
      second = LiteHM.run(plan)

      assert_equal first.to_h, second.to_h
      assert LiteHM.status(plan.id, connection: path).cut_over?
    end
  end

  def test_prepare_only_then_abort_preserves_source
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "messages-abort", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      status = LiteHM.run(plan, through: :ready)
      assert status.ready?

      database = SQLite3::Database.new(path)
      assert_equal %w[id body sent_at metadata],
        database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
      database.close

      aborted = LiteHM.abort(plan.id, connection: path)
      assert_equal "aborted", aborted.phase
      assert_raises(LiteHM::AbortUnavailable) { LiteHM.run(plan) }
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    ensure
      database&.close
    end
  end

  def test_invalid_planned_operation_can_be_aborted_and_releases_table_ownership
    Dir.mktmpdir("litehm-invalid-abort") do |directory|
      path = File.join(directory, "invalid.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE items(value TEXT);
        INSERT INTO items VALUES ('one');
      SQL
      database.close
      invalid = LiteHM.plan(:items, id: "invalid-locator", connection: path) do |table|
        table.add_column :flag, :integer
      end

      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(invalid) }
      assert_equal "planned", LiteHM.status(invalid.id, connection: path).phase
      assert_equal "aborted", LiteHM.abort(invalid.id, connection: path).phase
      replacement = LiteHM.plan(:items, id: "replacement", connection: path) do |table|
        table.add_column :other, :integer
      end
      assert_equal replacement, LiteHM.run(replacement, through: :planned)
    ensure
      database&.close
    end
  end

  def test_cleanup_releases_archive_in_bounded_batches
    with_database do |path|
      receipt = LiteHM.change_table(:messages, id: "messages-cleanup", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      status = LiteHM.cleanup(receipt.plan_id, connection: path)

      assert_equal "done", status.phase
      refute schema_snapshot(path).flatten.include?(receipt.archive_name)
      assert_equal "released", status.archive.fetch("state")
    end
  end
end
