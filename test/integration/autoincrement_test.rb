# frozen_string_literal: true

require_relative "../test_helper"

class AutoincrementTest < Minitest::Test
  def test_deleted_high_sequence_value_is_not_reused_after_cutover
    Dir.mktmpdir("litehm-sequence") do |directory|
      path = File.join(directory, "sequence.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL);
        INSERT INTO events(id, body) VALUES (1, 'keep'), (100, 'delete');
        DELETE FROM events WHERE id = 100;
      SQL
      assert_equal 100, database.get_first_value("SELECT seq FROM sqlite_sequence WHERE name = 'events'")
      database.close

      LiteHM.change_table(:events, id: "sequence-preservation", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO events(body) VALUES ('after')")
      assert_equal 101, database.get_first_value("SELECT id FROM events WHERE body = 'after'")
      assert_equal 101, database.get_first_value("SELECT seq FROM sqlite_sequence WHERE name = 'events'")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end
end
