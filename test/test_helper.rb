# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "litehm"

LiteHM.configuration.execution_mode = :inline

module DatabaseTestHelper
  def with_database
    Dir.mktmpdir("litehm-test") do |directory|
      path = File.join(directory, "test.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          body TEXT NOT NULL,
          sent_at INTEGER,
          metadata BLOB
        ) STRICT;
        CREATE INDEX index_messages_on_sent_at ON messages(sent_at);
        INSERT INTO messages(body, sent_at, metadata)
          VALUES ('hello', 1, X'00ff'), ('world', 2, NULL);
      SQL
      database.close
      yield path
    ensure
      database&.close unless database&.closed?
    end
  end

  def schema_snapshot(path)
    database = SQLite3::Database.new(path)
    database.execute(<<~SQL)
      SELECT type, name, tbl_name, sql
      FROM sqlite_schema
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY type, name
    SQL
  ensure
    database&.close
  end
end

class Minitest::Test
  include DatabaseTestHelper
end
