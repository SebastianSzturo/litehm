# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class ArchiveCleanupContentionTest < Minitest::Test
  ROWS = 200_000
  WRITER_TIMEOUT_MS = 50

  def teardown
    LiteHM::Testing.reset!
  end

  def test_ephemeral_archive_cleanup_yields_to_application_writers
    Dir.mktmpdir("litehm-cleanup-contention") do |directory|
      path = File.join(directory, "contention.sqlite3")
      create_database(path)
      plan = LiteHM.plan(:items, id: "cleanup-contention", connection: path,
        policy: { archive: :ephemeral }) do |table|
        table.add_index :parent_id, name: :index_items_on_parent_id
      end
      assert LiteHM.run(plan, through: :ready).ready?

      stop = File.join(directory, "writer-stop")
      ready = File.join(directory, "writer-ready")
      reader, writer = IO.pipe
      writer_pid = spawn_writer(path, stop:, ready:, reader:, writer:)
      writer.close
      wait_for_file(ready)

      receipt = LiteHM.run(plan)
      assert receipt.cut_over?
      File.write(stop, "stop")
      Process.wait(writer_pid)
      result = JSON.parse(reader.read)

      assert_operator result.fetch("writes"), :>, 0
      assert_empty result.fetch("busy_phases"),
        "archive cleanup starved an application writer for #{WRITER_TIMEOUT_MS}ms"
    ensure
      File.write(stop, "stop") if defined?(stop) && stop && !File.exist?(stop)
      Process.wait(writer_pid) if defined?(writer_pid) && writer_pid && process_running?(writer_pid)
      reader&.close
      writer&.close
    end
  end

  private

  def create_database(path)
    database = SQLite3::Database.new(path)
    database.execute_batch(<<~SQL)
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE parents(id INTEGER PRIMARY KEY);
      CREATE TABLE items(
        id INTEGER PRIMARY KEY,
        parent_id INTEGER NOT NULL REFERENCES parents(id),
        payload TEXT NOT NULL
      );
      CREATE INDEX items_parent_lookup ON items(parent_id);
      CREATE TABLE heartbeat(id INTEGER PRIMARY KEY, value INTEGER NOT NULL);
      INSERT INTO parents VALUES (1);
      INSERT INTO heartbeat VALUES (1, 0);
      WITH RECURSIVE series(id) AS (
        VALUES(1)
        UNION ALL SELECT id + 1 FROM series WHERE id < #{ROWS}
      )
      INSERT INTO items(id, parent_id, payload)
      SELECT id, 1, '' FROM series;
    SQL
  ensure
    database&.close
  end

  def spawn_writer(path, stop:, ready:, reader:, writer:)
    fork do
      reader.close
      connection = SQLite3::Database.new(path)
      connection.busy_timeout = WRITER_TIMEOUT_MS
      writes = 0
      busy_phases = []
      File.write(ready, Process.pid.to_s)
      until File.exist?(stop)
        begin
          connection.execute("UPDATE heartbeat SET value = value + 1 WHERE id = 1")
          writes += 1
        rescue SQLite3::BusyException
          phase = connection.get_first_value(
            "SELECT phase FROM litehm_plans WHERE plan_id = 'cleanup-contention'"
          )
          busy_phases << phase
        end
        sleep 0.001
      end
      writer.write(JSON.generate(writes:, busy_phases:))
      writer.close
      connection.close
      exit! 0
    end
  end

  def wait_for_file(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(path)
      raise "writer did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.001
    end
  end

  def process_running?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
