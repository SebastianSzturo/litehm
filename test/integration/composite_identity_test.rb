# frozen_string_literal: true

require_relative "../test_helper"

class CompositeIdentityTest < Minitest::Test
  def test_without_rowid_composite_text_blob_primary_key
    Dir.mktmpdir("litehm-composite") do |directory|
      path = File.join(directory, "composite.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE inventory (
          tenant TEXT NOT NULL COLLATE NOCASE,
          token BLOB NOT NULL,
          quantity INTEGER NOT NULL,
          note,
          PRIMARY KEY (tenant, token)
        ) WITHOUT ROWID;
      SQL
      database.execute("INSERT INTO inventory VALUES (?, ?, ?, ?)", ["Alpha", "\x00\xff".b, 3, 1.5])
      database.execute("INSERT INTO inventory VALUES (?, ?, ?, ?)", ["beta", "".b, 8, "text\0value"])
      database.close

      receipt = LiteHM.change_table(:inventory, id: "composite-key", connection: path) do |table|
        table.rename_column :quantity, :count
        table.add_column :available, :boolean, null: false, default: true
        table.add_index :count, name: :inventory_count
      end

      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      rows = database.execute("SELECT tenant, token, count, note, available FROM inventory ORDER BY tenant, token")
      assert_equal [
        ["Alpha", "\x00\xff".b, 3, 1.5, 1],
        ["beta", "".b, 8, "text\0value", 1]
      ], rows
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
      assert_equal "done", LiteHM.cleanup(receipt.plan_id, connection: path).phase
    ensure
      database&.close
    end
  end

  def test_nullable_ordinary_primary_key_is_rejected_before_artifacts
    Dir.mktmpdir("litehm-null-pk") do |directory|
      path = File.join(directory, "nullable.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE items(code TEXT PRIMARY KEY, value TEXT)")
      database.execute("INSERT INTO items(code, value) VALUES (NULL, 'ambiguous')")
      database.close
      plan = LiteHM.plan(:items, connection: path) { |table| table.add_column :flag, :integer }

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/UNIQUE NOT NULL locator/, error.message)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    ensure
      database&.close
    end
  end
end
