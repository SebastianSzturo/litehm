# frozen_string_literal: true

require_relative "../test_helper"

class CopyConflictTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_unique_value_move_across_copy_cursor_is_reconciled_and_retried
    with_database do |path|
      writer = nil
      database = SQLite3::Database.new(path)
      database.execute("CREATE UNIQUE INDEX messages_unique_body ON messages(body)")
      database.transaction do
        300.times do |index|
          database.execute("INSERT INTO messages(body, sent_at) VALUES (?, ?)", ["row-#{index}", index])
        end
      end
      destination_id = database.get_first_value("SELECT MAX(id) FROM messages")
      database.close

      moved = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_copy_batch_commit && !moved

        moved = true
        writer = SQLite3::Database.new(path)
        writer.transaction do
          writer.execute("UPDATE messages SET body = 'moved-away' WHERE id = 1")
          writer.execute("UPDATE messages SET body = 'hello' WHERE id = ?", [destination_id])
        end
        writer.close
      end
      receipt = LiteHM.change_table(:messages, id: "copy-unique-move", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal destination_id, database.get_first_value("SELECT id FROM messages WHERE body = 'hello'")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      writer&.close
      database&.close
    end
  end
end
