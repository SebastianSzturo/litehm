# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/job_reporting_schema"
require "active_record"

class JobReportingTest < Minitest::Test
  class FixtureRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  def teardown
    LiteHM::Testing.reset!
    FixtureRecord.connection_pool.disconnect! if FixtureRecord.connected?
  end

  def test_reporting_indexes_preserve_live_writes_and_inbound_foreign_keys
    Dir.mktmpdir("litehm-job-reporting") do |directory|
      path = File.join(directory, "reporting.sqlite3")
      FixtureRecord.establish_connection(adapter: "sqlite3", database: path)
      FixtureRecord.connection_pool.with_connection do |adapter|
        JobReportingSchema.install(adapter)
      end
      database = SQLite3::Database.new(path)
      database.execute("PRAGMA foreign_keys = ON")
      database.execute("INSERT INTO projects(id, title) VALUES (1, 'project')")
      database.execute("INSERT INTO projects(id, title) VALUES (2, 'deleted during copy')")
      database.execute(<<~SQL)
        WITH RECURSIVE ids(id) AS (SELECT 1 UNION ALL SELECT id + 1 FROM ids WHERE id < 600)
        INSERT INTO jobs(id, project_id, status, duration_ms, created_at, updated_at)
        SELECT id, 1, 'completed', id, '2026-01-01', '2026-01-01' FROM ids
      SQL
      database.execute("INSERT INTO job_steps(job_id) VALUES (1)")
      database.execute("INSERT INTO job_attempts(job_id) VALUES (1)")
      database.execute("UPDATE jobs SET project_id = 2 WHERE id = 3")

      plan = LiteHM.plan(:jobs, id: "job-reporting", connection: path,
        policy: { archive: :ephemeral }) do |table|
        table.add_index :id,
          where: "status = 'failed' OR error_message IS NOT NULL OR failure_reason IS NOT NULL",
          name: "index_jobs_on_problematic_id"
        table.add_index [:created_at, :duration_ms]
      end
      assert LiteHM.run(plan, through: :ready).ready?
      database.execute("DELETE FROM projects WHERE id = 2")
      assert_nil database.get_first_value("SELECT project_id FROM jobs WHERE id = 3")
      database.execute("UPDATE jobs SET status = 'failed', duration_ms = 999 WHERE id = 1")
      database.execute("UPDATE jobs SET error_message = 'upstream error' WHERE id = 2")
      database.execute("DELETE FROM jobs WHERE id = 600")
      database.execute(<<~SQL)
        INSERT INTO jobs(project_id, status, duration_ms, created_at, updated_at)
        VALUES (1, 'completed', 7, '2026-01-01', '2026-01-01')
      SQL
      expected = database.execute("SELECT * FROM jobs ORDER BY id")
      assert LiteHM.run(plan).cut_over?
      assert_equal "done", LiteHM.status(plan.id, connection: path).phase
      assert_equal expected, database.execute("SELECT * FROM jobs ORDER BY id")
      assert_empty database.execute("PRAGMA foreign_key_check")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
      FixtureRecord.connection_pool.with_connection do |adapter|
        names = adapter.indexes(:jobs).map(&:name)
        assert_includes names, "index_jobs_on_problematic_id"
        assert_includes names, "index_jobs_on_created_at_and_duration_ms"
      end
      problematic = LiteHM::SQL.identifier(LiteHM::SQL.artifact(
        "index_index_jobs_on_problematic_id", plan.id))
      assert_equal [[1], [2]], database.execute(<<~SQL)
        SELECT id FROM jobs INDEXED BY #{problematic}
        WHERE status = 'failed' OR error_message IS NOT NULL OR failure_reason IS NOT NULL ORDER BY id
      SQL
      database.execute("DELETE FROM projects WHERE id = 1")
      assert_equal 0, database.get_first_value("SELECT COUNT(*) FROM jobs WHERE project_id IS NOT NULL")
      assert_empty database.execute("PRAGMA foreign_key_check")
    ensure
      database&.close
    end
  end
end
