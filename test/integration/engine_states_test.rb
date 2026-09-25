# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"

# Renders the real engine pages for an operation in every dashboard state.
class EngineStatesTest < Minitest::Test
  EXPECTED = {
    # state => [chip, status line fragment, buttons in order]
    "waiting" => ["Waiting to start", "Not started", %w[Start Abort]],
    "queued" => ["Queued", "Waiting for a worker", %w[Pause Abort]],
    "running" => ["Running", "42.7% · 50 rows/s · ~11 s left", %w[Pause Abort]],
    "paused" => ["Paused", "Paused at 61%", %w[Resume Abort]],
    "catching_up" => ["Running", "Catching up on changes", %w[Pause Abort]],
    "validating" => ["Running", "Validating rows", %w[Pause Abort]],
    "ready" => ["Ready to cut over", "manual cutover", ["Cut over", "Pause", "Abort"]],
    "ready_automatic" => ["Running", "Ready · cutting over", ["Pause", "Cut over", "Abort"]],
    "cutover_requested" => ["Cutting over", "Cutover requested", ["Pause", "Cut over", "Abort"]],
    "failed" => ["Failed", "Copy failed", %w[Retry]],
    "failed_unpaused" => ["Failed", "Copy failed", %w[Retry]],
    "stalled" => ["Stalled", "Last commit 1 h ago", %w[Retry Pause Abort]],
    "abort_requested" => ["Aborting", "Dropping the shadow table", %w[Pause Abort]],
    "aborting" => ["Aborting", "Dropping the shadow table", []],
    "live_archive" => ["Live · archive kept", "old table kept", ["Release archive"]],
    "releasing" => ["Releasing archive", "Releasing the old table", []],
    "done" => ["Done", "archive released", []],
    "aborted" => ["Aborted", "Aborted", []],
    "legacy" => ["Running", "500 rows copied", %w[Pause Abort]]
  }.freeze

  def test_every_state_renders_plain_language_status_and_allowed_actions
    Dir.mktmpdir("litehm-engine-states") do |directory|
      app = File.expand_path("../dummy", __dir__)
      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "test" }, Gem.ruby, "script/states.rb", File.join(directory, "states.sqlite3"), chdir: app
      )
      assert status.success?, "states dummy failed:\n#{stdout}\n#{stderr}"
      result = JSON.parse(stdout.lines.last)

      index = result.fetch("index")
      assert_equal 200, index.fetch("status")
      assert_includes index.fetch("body"), %(<span class="attn">5 need you</span>)
      assert_includes index.fetch("body"), ">Done</h2>"
      refute_includes index.fetch("body"), "__litehm_"

      EXPECTED.each do |state, (chip, line, buttons)|
        page = result.fetch("pages").fetch(state)
        body = page.fetch("body")
        assert_equal 200, page.fetch("status"), state
        assert_includes body, ">#{chip}</span>", state
        assert_includes body, line, state
        assert_equal buttons, body.scan(%r{<button[^>]*>([^<]*)</button>}).flatten, state
        assert_equal 6, body.scan(%r{<span class="label">}).length, "#{state} track"
      end

      failed = result.fetch("pages").fetch("failed").fetch("body")
      assert_includes failed, "Some rows have NULL country_code, which the new schema forbids."
      refute_includes failed, ">Paused<"
      plain, raw = failed.split("<details>", 2)
      refute_includes plain, "__litehm_shadow", "internal names stay in the raw error"
      assert_includes raw, "NOT NULL constraint failed"

      stalled = result.fetch("pages").fetch("stalled").fetch("body")
      assert_includes stalled, "no worker holds the lease"

      running = result.fetch("pages").fetch("running").fetch("body")
      assert_includes running, "~1,000"
      assert_match %r{Worker <span>sampled \d+ s ago</span>}, running
      assert_includes running, "Add index on (value)"
      assert_includes running, %(data-litehm-confirm="Abort this migration? The shadow table is dropped.")
      assert_includes running, %(value="abort")

      legacy = result.fetch("pages").fetch("legacy").fetch("body")
      assert_includes legacy, "At least 251"
      assert_includes legacy, "No worker metrics yet."
    end
  end
end
