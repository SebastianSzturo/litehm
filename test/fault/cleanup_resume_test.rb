# frozen_string_literal: true

require_relative "../test_helper"

class CleanupResumeTest < Minitest::Test
  InjectedFailure = Class.new(StandardError)

  def teardown
    LiteHM::Testing.reset!
  end

  def test_recovery_promise_is_released_before_destructive_cleanup_and_cleanup_resumes
    with_database do |path|
      fill(path, 600)
      receipt = LiteHM.change_table(:messages, id: "cleanup-fault", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      failed = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_cleanup_batch && !failed

        failed = true
        raise InjectedFailure
      end

      assert_raises(InjectedFailure) { LiteHM.cleanup(receipt.plan_id, connection: path) }
      status = LiteHM.status(receipt.plan_id, connection: path)
      assert_equal "archive_released", status.phase
      assert_equal "releasing", status.archive.fetch("state")
      connection = LiteHM::Connection.open(path)
      durable_receipt = LiteHM::Store.new(connection).receipt(receipt.plan_id)
      connection.close
      assert_nil durable_receipt.archive_name

      LiteHM::Testing.reset!
      finished = LiteHM.cleanup(receipt.plan_id, connection: path)
      assert_equal "done", finished.phase
      refute schema_snapshot(path).flatten.include?(receipt.archive_name)
      assert_equal "ok", integrity(path)
    end
  end

  private

  def fill(path, count)
    database = SQLite3::Database.new(path)
    database.transaction do
      count.times { |index| database.execute("INSERT INTO messages(body) VALUES (?)", ["extra-#{index}"]) }
    end
  ensure
    database&.close
  end

  def integrity(path)
    database = SQLite3::Database.new(path)
    database.get_first_value("PRAGMA integrity_check")
  ensure
    database&.close
  end
end
