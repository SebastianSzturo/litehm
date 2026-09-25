# frozen_string_literal: true

require "fileutils"
require "json"

ENV["RAILS_ENV"] = "test"
database_path = File.expand_path(ARGV.fetch(0))
row_count = Integer(ARGV.fetch(1, "1000000"), 10)
payload_bytes = Integer(ARGV.fetch(2, "256"), 10)
raise ArgumentError, "row count must be positive" unless row_count.positive?
raise ArgumentError, "payload bytes must be positive" unless payload_bytes.positive?

ENV["LITEHM_FIXTURE_DATABASE"] = database_path
require_relative "../config/environment"

def monotonic_time
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def file_size(path)
  File.size(path)
rescue Errno::ENOENT
  0
end

FileUtils.rm_f([database_path, "#{database_path}-wal", "#{database_path}-shm"])
ActiveRecord::Base.establish_connection

ActiveRecord::Schema.define do
  create_table :messages, force: true do |table|
    table.text :body, null: false
    table.integer :sent_at
  end
end

connection = ActiveRecord::Base.connection
connection.execute("PRAGMA journal_mode = WAL")
connection.execute("PRAGMA synchronous = NORMAL")
warn "Seeding #{row_count} rows with #{payload_bytes}-byte payloads..."
seed_started = monotonic_time
connection.execute(<<~SQL)
  WITH RECURSIVE series(id) AS (
    VALUES(1)
    UNION ALL
    SELECT id + 1 FROM series WHERE id < #{row_count}
  )
  INSERT INTO messages(id, body, sent_at)
  SELECT id,
    printf('message-%08d-', id) || substr(hex(zeroblob(#{(payload_bytes + 1) / 2})), 1, #{payload_bytes}),
    id % 1000000
  FROM series
SQL
seed_seconds = monotonic_time - seed_started
connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
initial_database_bytes = file_size(database_path)

stop_path = "#{database_path}.writer-stop"
ready_path = "#{database_path}.writer-ready"
result_path = "#{database_path}.writer-result.json"
FileUtils.rm_f([stop_path, ready_path, result_path])

writer_pid = fork do
  ActiveRecord::Base.connection_pool.disconnect! rescue nil
  writer = SQLite3::Database.new(database_path)
  writer.busy_timeout = 500
  inserted = 0
  updated = 0
  busy = 0
  schema_retries = 0
  unexpected = []
  next_id = row_count + 1
  max_database_bytes = file_size(database_path)
  max_wal_bytes = 0
  FileUtils.touch(ready_path)

  until File.exist?(stop_path)
    begin
      columns = writer.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
      content_column = columns.include?("body") ? "body" : "content"
      writer.execute(
        "INSERT INTO messages(id, #{content_column}, sent_at) VALUES (?, ?, ?)",
        [next_id, "writer-#{next_id}-#{'w' * [payload_bytes - 24, 1].max}", next_id % 1000000]
      )
      inserted += 1
      next_id += 1
      target = 1 + (inserted % row_count)
      writer.execute("UPDATE messages SET sent_at = sent_at + 1 WHERE id = ?", [target])
      updated += 1
    rescue SQLite3::BusyException
      busy += 1
    rescue SQLite3::SQLException => error
      if error.message.match?(/no column named|has no column named/i)
        schema_retries += 1
      else
        unexpected << error.message
      end
    ensure
      max_database_bytes = [max_database_bytes, file_size(database_path)].max
      max_wal_bytes = [max_wal_bytes, file_size("#{database_path}-wal")].max
    end
    sleep 0.002
  end

  File.write(result_path, JSON.generate(
    inserted:, updated:, busy:, schema_retries:, unexpected: unexpected.uniq,
    max_database_bytes:, max_wal_bytes:
  ))
  writer.close
  exit! 0
end

deadline = monotonic_time + 10
sleep 0.01 until File.exist?(ready_path) || monotonic_time >= deadline
raise "writer process did not become ready" unless File.exist?(ready_path)

warn "Running the real Rails migration with a concurrent writer..."
begin
  migration_started = monotonic_time
  migrations = File.expand_path("../db/migrate", __dir__)
  pool = ActiveRecord::Base.connection_pool
  context = ActiveRecord::MigrationContext.new(migrations, pool.schema_migration, pool.internal_metadata)
  context.migrate
  migration_seconds = monotonic_time - migration_started
ensure
  FileUtils.touch(stop_path) if defined?(stop_path) && stop_path
  if defined?(writer_pid) && writer_pid
    begin
      Process.wait(writer_pid)
    rescue Errno::ECHILD
      nil
    end
  end
end

writer_result = JSON.parse(File.read(result_path))
connection = ActiveRecord::Base.connection
actual_rows = connection.select_value("SELECT COUNT(*) FROM messages").to_i
expected_rows = row_count + writer_result.fetch("inserted")
raise "row-count mismatch: expected #{expected_rows}, got #{actual_rows}" unless actual_rows == expected_rows

columns = connection.select_rows("PRAGMA table_xinfo(messages)").map { |row| row[1] }
expected_columns = %w[id content sent_at delivered]
raise "column mismatch: #{columns.inspect}" unless columns == expected_columns
raise "NULL content found" unless connection.select_value("SELECT COUNT(*) FROM messages WHERE content IS NULL").to_i.zero?
raise "non-default delivered value found" unless connection.select_value("SELECT COUNT(*) FROM messages WHERE delivered != 0").to_i.zero?

logical_indexes = connection.indexes(:messages).map(&:name).sort
raise "logical delivery index missing" unless logical_indexes.include?("messages_delivery")
integrity = connection.select_value("PRAGMA integrity_check")
foreign_key_violations = connection.select_rows("PRAGMA foreign_key_check")
raise "integrity check failed: #{integrity}" unless integrity == "ok"
raise "foreign-key violations: #{foreign_key_violations.inspect}" unless foreign_key_violations.empty?

status = LiteHM.status("rails-fixture-delivery", connection: connection)
archive_name = status.archive.fetch("name")
archive_rows = connection.select_value(
  "SELECT COUNT(*) FROM #{LiteHM::SQL.identifier(archive_name)}"
).to_i
physical_indexes = connection.select_values(<<~SQL)
  SELECT physical_name FROM litehm_index_names
  WHERE table_name = 'messages' AND active = 1 ORDER BY physical_name
SQL
allowed_artifacts = [archive_name, *physical_indexes]
allowed_placeholders = allowed_artifacts.map { connection.quote(_1) }.join(", ")
transient_before_cleanup = connection.select_values(<<~SQL)
  SELECT name FROM sqlite_schema
  WHERE name LIKE '__litehm_%' AND name NOT IN (#{allowed_placeholders})
  ORDER BY name
SQL
raise "transient LiteHM artifacts remain after cutover: #{transient_before_cleanup.inspect}" unless transient_before_cleanup.empty?

warn "Cleaning the retained archive in bounded batches..."
cleanup_started = monotonic_time
cleanup_status = LiteHM.cleanup("rails-fixture-delivery", connection: connection)
cleanup_seconds = monotonic_time - cleanup_started
connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
artifacts_after_cleanup = connection.select_values(<<~SQL)
  SELECT name FROM sqlite_schema
  WHERE name LIKE '__litehm_%' AND name NOT IN (#{physical_indexes.map { connection.quote(_1) }.join(', ')})
  ORDER BY name
SQL
raise "LiteHM artifacts remain after cleanup: #{artifacts_after_cleanup.inspect}" unless artifacts_after_cleanup.empty?

sample_ids = [1, (row_count / 2.0).ceil, actual_rows]
samples = connection.exec_query(<<~SQL).to_a
  SELECT id, length(content) AS content_bytes, sent_at, delivered
  FROM messages WHERE id IN (#{sample_ids.join(', ')}) ORDER BY id
SQL

puts JSON.generate(
  rails_version: Rails.version,
  active_record_version: ActiveRecord.version.to_s,
  sqlite_version: connection.select_value("SELECT sqlite_version()"),
  rows_seeded: row_count,
  payload_bytes:, seed_seconds: seed_seconds.round(3),
  migration_seconds: migration_seconds.round(3),
  cleanup_seconds: cleanup_seconds.round(3),
  writer: writer_result,
  expected_rows:, actual_rows:, archive_rows:,
  initial_database_bytes:,
  final_database_bytes: file_size(database_path),
  final_wal_bytes: file_size("#{database_path}-wal"),
  freelist_pages: connection.select_value("PRAGMA freelist_count").to_i,
  columns:, logical_indexes:, physical_indexes:, transient_before_cleanup:, artifacts_after_cleanup:,
  migration_versions: context.get_all_versions,
  litehm_phase: cleanup_status.phase,
  integrity:, foreign_key_violations:, samples:
)
