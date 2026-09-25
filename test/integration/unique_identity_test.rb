# frozen_string_literal: true

require_relative "../test_helper"

class UniqueIdentityTest < Minitest::Test
  def test_unique_not_null_key_is_used_when_table_has_no_primary_key
    Dir.mktmpdir("litehm-unique") do |directory|
      path = File.join(directory, "unique.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE events (
          account TEXT NOT NULL,
          external_id BLOB NOT NULL,
          payload,
          UNIQUE (account, external_id)
        );
      SQL
      database.execute("INSERT INTO events VALUES (?, ?, ?)", ["one", "\xff".b, "payload"])
      database.close

      receipt = LiteHM.change_table(:events, id: "unique-locator", connection: path) do |table|
        table.rename_column :payload, :body
        table.add_column :processed, :boolean, null: false, default: false
        table.add_index %i[account external_id], unique: true, name: :events_identity
      end

      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal [["one", "\xff".b, "payload", 0]],
        database.execute("SELECT account, external_id, body, processed FROM events")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
      assert_equal "done", LiteHM.cleanup(receipt.plan_id, connection: path).phase
    ensure
      database&.close
    end
  end

  def test_bare_rowid_source_is_rejected_before_capture
    Dir.mktmpdir("litehm-rowid") do |directory|
      path = File.join(directory, "rowid.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE events(payload TEXT)")
      database.close
      plan = LiteHM.plan(:events, connection: path) { |table| table.add_column :flag, :integer }

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/UNIQUE NOT NULL locator/, error.message)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    ensure
      database&.close
    end
  end
end
