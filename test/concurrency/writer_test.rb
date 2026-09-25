# frozen_string_literal: true

require_relative "../test_helper"

class ConcurrentWriterTest < Minitest::Test
  def test_independent_writer_spans_copy_and_cutover_without_lost_writes
    with_database do |path|
      fill(path, 5_000)
      started = Queue.new
      stop = false
      writes = 0
      writer_error = nil
      writer = Thread.new do
        database = SQLite3::Database.new(path)
        # Release the GVL while waiting so the in-process runner can finish its batch.
        database.busy_handler_timeout = 10_000
        started << true
        until stop
          database.transaction(:immediate) do
            database.execute("UPDATE messages SET sent_at = COALESCE(sent_at, 0) + 1 WHERE id = 1")
            database.execute("INSERT INTO messages(body, sent_at) VALUES (?, ?)", ["concurrent-#{writes}", writes])
          end
          writes += 1
          # A steady few hundred writes per second. An unpaced writer can outrun
          # LiteHM's deliberately paced drain on a small CI host, and readiness
          # then (correctly) gives up instead of starving the application.
          sleep 0.003
        end
      rescue StandardError => error
        writer_error = error
      ensure
        database&.close
      end
      started.pop

      receipt = LiteHM.change_table(:messages, id: "concurrent-writer", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
        table.add_index :flag, name: :messages_flag
      end
      stop = true
      writer.join

      assert receipt.cut_over?
      assert_nil writer_error
      assert_operator writes, :>, 0
      database = SQLite3::Database.new(path)
      assert_equal writes, database.get_first_value("SELECT sent_at FROM messages WHERE id = 1") - 1
      assert_equal 5_002 + writes, database.get_first_value("SELECT COUNT(*) FROM messages")
      assert_equal 0, database.get_first_value("SELECT COUNT(*) FROM messages WHERE flag != 0 OR flag IS NULL")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      stop = true
      writer&.join(1)
      database&.close
    end
  end

  private

  def fill(path, count)
    database = SQLite3::Database.new(path)
    database.transaction do
      count.times { |index| database.execute("INSERT INTO messages(body, sent_at) VALUES (?, ?)", ["seed-#{index}", index]) }
    end
  ensure
    database&.close
  end
end
