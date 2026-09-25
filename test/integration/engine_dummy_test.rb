# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"

class EngineDummyTest < Minitest::Test
  def test_fresh_rails_app_runs_engine_and_continuable_job_across_restart_and_crash
    Dir.mktmpdir("litehm-engine-dummy") do |directory|
      database = File.join(directory, "dummy.sqlite3")
      app = File.expand_path("../dummy", __dir__)
      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "test" }, Gem.ruby, "script/run.rb", database, chdir: app
      )
      assert status.success?, "Rails engine dummy failed:\n#{stdout}\n#{stderr}"

      result = JSON.parse(stdout.lines.last)
      # The migration only schedules the work: nothing is copied or run inline.
      # (Wall-clock bounds flake on shared CI runners; this state cannot.)
      assert_equal "planned", result.fetch("submitted_phase")
      assert_equal 0, result.fetch("submitted_copied_rows")
      assert_equal 0, result.fetch("submitted_jobs_performed")
      assert_operator result.fetch("migration_seconds"), :<, 30.0
      assert_equal %w[id body sent_at], result.fetch("submitted_columns")
      assert result.fetch("migration_version_recorded")
      assert_equal "litehm", result.fetch("queue")
      assert_equal 403, result.fetch("unauthorized_status")
      assert_equal 200, result.fetch("authorized_status")
      assert result.fetch("index_page_links_icon")
      assert_equal 200, result.fetch("icon_status")
      assert_equal "image/png", result.fetch("icon_content_type")
      assert_includes result.fetch("icon_cache_control"), "private"
      assert result.fetch("icon_png")
      assert_equal 403, result.fetch("unauthorized_icon_status")
      assert result.fetch("index_page_includes_plan")
      assert result.fetch("paused")
      assert_equal Signal.list.fetch("KILL"), result.fetch("crash_signal")
      assert result.fetch("restarted_worker")
      assert_equal "cut_over", result.fetch("final_phase")
      assert_equal %w[id body sent_at searchable], result.fetch("final_columns")
      assert_equal 100_001, result.fetch("row_count")
      assert_includes result.fetch("index_names"), "messages_searchable_sent_at"
      assert_equal 200, result.fetch("show_status")
      assert_includes result.fetch("cache_control"), "no-store"
      assert result.fetch("show_includes_progress")
      assert result.fetch("show_includes_metrics")
      assert result.fetch("show_includes_checkpoint")
      assert_operator result.fetch("persisted_copy_rows"), :>, 0
      assert result.fetch("capped_sample_visible")
      assert result.fetch("legacy_sample_visible")
      assert result.fetch("stalled_visible")
      assert result.fetch("deferred_visible")
      assert_equal "ok", result.fetch("integrity")
    end
  end
end
