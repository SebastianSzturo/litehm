# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"

class RailsFixtureTest < Minitest::Test
  def test_real_rails_application_runs_litehm_migration
    Dir.mktmpdir("litehm-rails") do |directory|
      database = File.join(directory, "rails.sqlite3")
      script = File.expand_path("../fixtures/rails_app/script/run.rb", __dir__)
      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "test" }, Gem.ruby, script, database,
        chdir: File.expand_path("../fixtures/rails_app", __dir__)
      )
      assert status.success?, "Rails fixture failed:\n#{stdout}\n#{stderr}"

      result = JSON.parse(stdout.lines.last)
      assert_equal %w[id content sent_at delivered], result.dig("up", "columns")
      assert_equal "from rails", result.dig("up", "row", "content")
      assert_equal false, result.dig("up", "row", "delivered")
      assert_includes result.dig("up", "migration_versions"), 20_260_818_000_000
      assert_equal "cut_over", result.dig("up", "litehm_phase")
      assert_equal %w[id body sent_at], result.dig("down", "columns")
      assert_equal "from rails", result.dig("down", "row", "body")
      refute_includes result.dig("down", "migration_versions"), 20_260_818_000_000
      assert_equal "cut_over", result.dig("down", "litehm_phase")
      assert_equal "ok", result.fetch("integrity")
    end
  end
end
