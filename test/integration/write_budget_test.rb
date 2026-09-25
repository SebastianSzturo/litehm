# frozen_string_literal: true

require_relative "../test_helper"

class WriteBudgetTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_large_payloads_use_small_batches_and_preflight_does_not_hold_the_writer
    with_database do |path|
      writer = SQLite3::Database.new(path)
      writer.busy_timeout = 0
      writer.execute("UPDATE messages SET metadata = zeroblob(131072)")
      12.times { writer.execute("INSERT INTO messages(body, metadata) VALUES ('payload', zeroblob(131072))") }
      plan = LiteHM.plan(:messages, connection: path,
        policy: { archive: :ephemeral, max_batch_bytes: 64 * 1024 }) do |table|
        table.add_column :flag, :integer, default: 0, null: false
      end
      batches = []
      writes = 0
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :batch_selected

        assert_equal 1, context[:rows] if context[:bytes] > 64 * 1024
        if context[:kind] == :copy
          # A different connection can write at this point: payload reads and
          # warming must finish before LiteHM acquires BEGIN IMMEDIATE.
          writer.execute("UPDATE messages SET sent_at = ? WHERE id = 1", [writes])
          writes += 1
          batches << context[:rows]
        end
      end
      assert LiteHM.run(plan).cut_over?
      assert_operator writes, :>, 1
      assert_equal [1], batches.uniq
      assert_equal writes - 1, writer.get_first_value("SELECT sent_at FROM messages WHERE id = 1")
      assert_equal 14, writer.get_first_value("SELECT COUNT(*) FROM messages WHERE length(metadata) = 131072 AND flag = 0")
      assert_equal "ok", writer.get_first_value("PRAGMA integrity_check")
    ensure
      writer&.close
    end
  end

  def test_oversized_row_stops_migration_without_refusing_application_writes
    with_database do |path|
      writer = SQLite3::Database.new(path)
      writer.execute("UPDATE messages SET metadata = zeroblob(4096) WHERE id = 1")
      plan = LiteHM.plan(:messages, connection: path, policy: { max_row_bytes: 1024 }) do |table|
        table.add_column :flag, :integer, default: 0
      end
      error = assert_raises(LiteHM::BusyBudgetExceeded) { LiteHM.run(plan) }
      assert_equal 1024, error.details[:max_row_bytes]
      writer.execute("UPDATE messages SET body = 'still writable' WHERE id = 1")
      assert_equal "still writable", writer.get_first_value("SELECT body FROM messages WHERE id = 1")
      assert_equal 4096, writer.get_first_value("SELECT length(metadata) FROM messages WHERE id = 1")
      LiteHM.abort(plan.id, connection: path)
      assert_equal "aborted", LiteHM.status(plan.id, connection: path).phase
    ensure
      writer&.close
    end
  end

  def test_removing_a_large_column_does_not_bypass_archive_payload_limit
    with_database do |path|
      SQLite3::Database.open(path) { |database| database.execute("UPDATE messages SET metadata = zeroblob(4096)") }
      plan = LiteHM.plan(:messages, connection: path, policy: { max_row_bytes: 1024 }) do |table|
        table.remove_column :metadata
      end
      assert_raises(LiteHM::BusyBudgetExceeded) { LiteHM.run(plan) }
      refute LiteHM.status(plan.id, connection: path).cut_over?
      LiteHM.abort(plan.id, connection: path)
    end
  end

  def test_row_growth_after_preflight_is_rechecked_before_copy
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path, policy: { max_row_bytes: 1024 }) do |table|
        table.add_column :flag, :integer, default: 0
      end
      grew = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :batch_selected && context[:kind] == :copy && !grew

        grew = true
        SQLite3::Database.open(path) do |writer|
          writer.execute("UPDATE messages SET metadata = zeroblob(4096) WHERE id = 1")
        end
      end
      assert_raises(LiteHM::BusyBudgetExceeded) { LiteHM.run(plan) }
      assert grew
      refute LiteHM.status(plan.id, connection: path).cut_over?
      SQLite3::Database.open(path) do |writer|
        writer.execute("UPDATE messages SET body = 'still writable' WHERE id = 1")
        assert_equal 4096, writer.get_first_value("SELECT length(metadata) FROM messages WHERE id = 1")
      end
      LiteHM.abort(plan.id, connection: path)
    end
  end

  def test_final_tail_rejects_oversized_projection_at_readiness_and_cutover
    [:before_ready_acquire, :before_cutover_acquire].each do |boundary|
      with_database do |path|
        plan = LiteHM.plan(:messages, connection: path, policy: { max_row_bytes: 1024 }) do |table|
          table.project :body, "body || body"
        end
        grew = false
        LiteHM::Testing.fault_injector = lambda do |point, _context|
          next unless point == boundary && !grew

          grew = true
          SQLite3::Database.open(path) do |writer|
            writer.execute("UPDATE messages SET body = ? WHERE id = 1", ["x" * 600])
          end
        end
        error = assert_raises(LiteHM::BusyBudgetExceeded) { LiteHM.run(plan) }
        assert grew
        assert_equal 1024, error.details[:max_row_bytes]
        refute LiteHM.status(plan.id, connection: path).cut_over?
        SQLite3::Database.open(path) do |writer|
          assert_equal 600, writer.get_first_value("SELECT length(body) FROM messages WHERE id = 1")
          writer.execute("UPDATE messages SET body = 'still writable' WHERE id = 1")
        end
        LiteHM::Testing.reset!
        assert LiteHM.run(plan).cut_over?
        SQLite3::Database.open(path) do |database|
          assert_equal "still writablestill writable", database.get_first_value("SELECT body FROM messages WHERE id = 1")
          assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
        end
      end
    end
  end

  def test_generated_payload_is_bounded_during_copy_and_final_reconciliation
    [nil, :before_ready_acquire, :before_cutover_acquire].each do |boundary|
      %w[STORED VIRTUAL].each do |storage|
        with_database do |path|
          plan = LiteHM.plan(:messages, connection: path, adapter: :raw,
            policy: { max_row_bytes: 1024 }) do |table|
            expression = boundary ? "body || body" : "zeroblob(4096)"
            table.ddl <<~SQL
              DROP TABLE #{table.name};
              CREATE TABLE #{table.name}(id INTEGER PRIMARY KEY, body TEXT NOT NULL,
                sent_at INTEGER, metadata BLOB, expanded GENERATED ALWAYS AS (#{expression}) #{storage});
            SQL
          end
          grew = false
          LiteHM::Testing.fault_injector = lambda do |point, _context|
            next unless boundary && point == boundary && !grew

            grew = true
            SQLite3::Database.open(path) { |writer| writer.execute("UPDATE messages SET body = ? WHERE id = 1", ["x" * 600]) }
          end
          error = assert_raises(LiteHM::BusyBudgetExceeded) { LiteHM.run(plan) }
          assert_equal 1024, error.details[:max_row_bytes]
          assert_operator error.details[:row_bytes], :>, 1024
          refute LiteHM.status(plan.id, connection: path).cut_over?
          SQLite3::Database.open(path) do |writer|
            writer.execute("UPDATE messages SET body = 'still writable' WHERE id = 1")
            assert_equal "still writable", writer.get_first_value("SELECT body FROM messages WHERE id = 1")
          end
          LiteHM::Testing.reset!
          assert_equal "aborted", LiteHM.abort(plan.id, connection: path).phase
        end
      end
    end
  end

  def test_generated_values_contribute_to_batch_bytes_without_losing_small_rows
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path, adapter: :raw,
        policy: { max_batch_bytes: 1024, max_row_bytes: 8192 }) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(id INTEGER PRIMARY KEY, body TEXT NOT NULL,
            sent_at INTEGER, metadata BLOB, expanded BLOB GENERATED ALWAYS AS (zeroblob(4096)) STORED);
        SQL
      end
      batches = []
      LiteHM::Testing.fault_injector = lambda do |point, context|
        batches << context if point == :batch_selected && context[:kind] == :copy && context[:rows].positive?
      end
      assert LiteHM.run(plan).cut_over?
      assert_equal [1, 1], batches.map { |batch| batch[:rows] }
      assert batches.all? { |batch| batch[:bytes] >= 4096 }
      SQLite3::Database.open(path) do |database|
        assert_equal [[4096], [4096]], database.execute("SELECT length(expanded) FROM messages ORDER BY id")
        assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
      end
    end
  end

  def test_new_inserts_do_not_extend_the_copy_frontier
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) { |table| table.add_column :flag, :integer, default: 0 }
      copied = 0
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :after_copy_batch_commit

        copied += context[:rows]
        SQLite3::Database.open(path) { |writer| writer.execute("INSERT INTO messages(body) VALUES ('new tail')") }
      end
      assert LiteHM.run(plan).cut_over?
      assert_equal 2, copied
      SQLite3::Database.open(path) do |database|
        assert_equal 3, database.get_first_value("SELECT COUNT(*) FROM messages")
        assert_equal 0, database.get_first_value("SELECT flag FROM messages WHERE body = 'new tail'")
      end
    end
  end

  def test_borrowed_application_busy_handler_survives_planning_and_execution
    with_database do |path|
      application = SQLite3::Database.new(path)
      blocker = SQLite3::Database.new(path)
      calls = 0
      application.busy_handler { |_count| calls += 1; false }
      plan = LiteHM.plan(:messages, connection: application) { |table| table.add_index :body }
      assert LiteHM.run(plan, connection: application).cut_over?
      blocker.execute("BEGIN IMMEDIATE")
      assert_raises(SQLite3::BusyException) { application.execute("UPDATE messages SET sent_at = 5 WHERE id = 1") }
      assert_operator calls, :>, 0
      blocker.execute("ROLLBACK")
      application.execute("UPDATE messages SET sent_at = 5 WHERE id = 1")
    ensure
      blocker&.close
      application&.close
    end
  end

  def test_passive_checkpoints_release_the_writer_and_tolerate_a_pinned_reader
    with_database do |path|
      application = SQLite3::Database.new(path)
      application.execute("PRAGMA cache_size = -1024")
      reader = SQLite3::Database.new(path)
      reader.execute("BEGIN")
      reader.get_first_value("SELECT COUNT(*) FROM messages")
      plan = LiteHM.plan(:messages, connection: application) { |table| table.add_index :body }
      checkpoints = []
      cache_bytes = nil
      LiteHM::Testing.fault_injector = lambda do |point, context|
        if point == :after_passive_checkpoint
          checkpoints << context.fetch(:result)
          application.execute("UPDATE messages SET sent_at = 7 WHERE id = 1")
        elsif point == :before_final_validation
          cache_bytes = -context.fetch(:database).get_first_value("PRAGMA cache_size") * 1024
        end
      end
      assert LiteHM.run(plan, connection: application).cut_over?
      assert_operator checkpoints.length, :>, 0
      assert checkpoints.any? { |(_busy, log, copied)| copied < log }
      assert_operator cache_bytes, :>=, 64 * 1024 * 1024
      assert_equal(-1024, application.get_first_value("PRAGMA cache_size"))
      reader.execute("ROLLBACK")
      assert_equal 7, application.get_first_value("SELECT sent_at FROM messages WHERE id = 1")
      assert_equal "ok", application.get_first_value("PRAGMA integrity_check")
    ensure
      reader&.close
      application&.close
    end
  end

  def test_failure_recording_waits_for_application_writer_without_replacing_its_busy_handler
    with_database do |path|
      application = SQLite3::Database.new(path)
      calls = 0
      application.busy_handler { |_count| calls += 1; false }
      plan = LiteHM.plan(:messages, connection: path) { |table| table.add_index :body }
      LiteHM.run(plan, through: :planned)
      entered = Queue.new
      release = Thread.new do
        SQLite3::Database.open(path) do |writer|
          writer.execute("BEGIN IMMEDIATE")
          entered << true
          sleep 0.05
          writer.execute("COMMIT")
        end
      end
      entered.pop
      LiteHM.record_failure(plan.id, application, LiteHM::Error.new("example"))
      release.value
      assert LiteHM.status(plan.id, connection: path).error
      assert_equal 0, calls
      SQLite3::Database.open(path) do |blocker|
        blocker.execute("BEGIN IMMEDIATE")
        assert_raises(SQLite3::BusyException) { application.execute("UPDATE messages SET sent_at = 5") }
        assert_operator calls, :>, 0
        blocker.execute("ROLLBACK")
      end
    ensure
      release&.join
      application&.close
    end
  end

  def test_batch_waits_for_application_writer_without_failing_the_migration
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path,
        policy: { busy_timeout_ms: 5 }) { |table| table.add_column :flag, :integer, default: 0 }
      release = nil
      deferred = 0
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        if point == :after_prepare_commit
          entered = Queue.new
          release = Thread.new do
            SQLite3::Database.open(path) do |writer|
              writer.execute("BEGIN IMMEDIATE")
              writer.execute("UPDATE messages SET sent_at = 42 WHERE id = 1")
              entered << true
              sleep 0.05
              writer.execute("COMMIT")
            end
          end
          entered.pop
        elsif point == :writer_lock_deferred
          deferred += 1
        end
      end
      assert LiteHM.run(plan).cut_over?
      release.value
      assert_operator deferred, :>, 0
      SQLite3::Database.open(path) do |database|
        assert_equal 42, database.get_first_value("SELECT sent_at FROM messages WHERE id = 1")
      end
    ensure
      release&.join
    end
  end

  def test_final_tail_with_few_large_rows_is_drained_outside_cutover
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path,
        policy: { max_batch_bytes: 8192 }) { |table| table.add_column :flag, :integer, default: 0 }
      inserted = false
      deferred = []
      LiteHM::Testing.fault_injector = lambda do |point, context|
        if point == :before_ready_acquire && !inserted
          inserted = true
          SQLite3::Database.open(path) do |writer|
            writer.execute("UPDATE messages SET metadata = zeroblob(65536) WHERE id = 1")
          end
        elsif point == :tail_deferred
          deferred << context[:rows]
        end
      end
      assert LiteHM.run(plan).cut_over?
      assert_includes deferred, 1
      SQLite3::Database.open(path) do |database|
        assert_equal 65536, database.get_first_value("SELECT length(metadata) FROM messages WHERE id = 1")
        assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
      end
    end
  end
end
