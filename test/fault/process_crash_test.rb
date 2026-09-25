# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"

class ProcessCrashTest < Minitest::Test
  POINTS = %w[
    after_prepare_commit
    after_copy_batch_commit
    before_cutover_commit
    after_cutover_commit
  ].freeze

  def test_sigkill_boundaries_recover_and_resume_from_database_state
    POINTS.each do |point|
      with_database do |path|
        fill(path, 600)
        worker = File.expand_path("../support/crash_worker.rb", __dir__)
        pid = Process.spawn(RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}",
          worker, path, point, out: File::NULL, err: File::NULL)
        _pid, status = Process.wait2(pid)
        assert status.signaled?, "worker at #{point} exited normally"
        assert_equal Signal.list.fetch("KILL"), status.termsig

        database = SQLite3::Database.new(path)
        assert_equal "ok", database.get_first_value("PRAGMA quick_check"), point
        assert_empty database.execute("PRAGMA foreign_key_check"), point
        database.close
        sleep 0.03

        plan = LiteHM.plan(:messages, id: "process-crash", connection: path,
          policy: { lease_ttl_ms: 20 }) do |table|
          table.add_column :flag, :integer, null: false, default: 0
        end
        receipt = LiteHM.run(plan)
        assert receipt.cut_over?, point
        database = SQLite3::Database.new(path)
        assert_equal 602, database.get_first_value("SELECT COUNT(*) FROM messages"), point
        assert_equal 0, database.get_first_value("SELECT COUNT(*) FROM messages WHERE flag != 0 OR flag IS NULL"), point
        assert_equal "ok", database.get_first_value("PRAGMA integrity_check"), point
      ensure
        database&.close
      end
    end
  end

  private

  def fill(path, count)
    database = SQLite3::Database.new(path)
    database.transaction do
      count.times { |index| database.execute("INSERT INTO messages(body) VALUES (?)", ["crash-#{index}"]) }
    end
  ensure
    database&.close
  end
end
