# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/helpers/litehm/operation_summary"

class OperationSummaryTest < Minitest::Test
  NOW = Time.utc(2026, 9, 25, 10, 0, 0)
  PHASES = %w[planned preparing ready aborting cut_over archive_released done aborted].freeze
  DESIRED = %w[running paused cutover_requested abort_requested cleanup_requested].freeze
  ERROR = { "class" => "LiteHM::DataIncompatible", "message" => "source projection violates a target constraint during copy",
    "details" => { "sqlite_error" => "NOT NULL constraint failed: __litehm_shadow_2a969c.country_code" } }.freeze

  def status(**overrides)
    LiteHM::Status.new(**{
      plan_id: "20260915-messages-delivered-flag", table: "messages", phase: "preparing",
      source_hash: "s", target_hash: "t", error: nil, progress: {}, archive: {}, retry_action: "resume",
      desired_state: "running", execution_revision: 1, last_advanced_at: at(3), created_at: at(3_600),
      updated_at: at(3), stalled: false, recovery_enqueued_at: nil,
      intent: [["add_index", ["sent_at"], {}]], policy: { "cutover" => "automatic", "archive" => "retain" },
      cutover_at: nil
    }.merge(overrides))
  end

  def summary(**overrides)
    LiteHM::OperationSummary.new(status(**overrides), now: NOW)
  end

  def at(seconds_ago)
    (NOW - seconds_ago).iso8601(6)
  end

  def integer(value)
    [{ "type" => "integer", "value" => value }]
  end

  # The command buttons the engine rendered before the dashboard redesign.
  def previous_actions(status)
    list = []
    list << "retry" if status.stalled?
    if status.error && !status.terminal?
      list << "retry"
    elsif %w[planned preparing ready].include?(status.phase)
      list << (status.paused? ? "resume" : "pause")
      list << "cutover" if status.ready?
      list << "abort"
    end
    list << "cleanup" if status.cut_over? && status.archive["state"] == "retained"
    list.uniq
  end

  def test_every_combination_maps_to_a_state_and_keeps_the_previous_actions
    PHASES.product(DESIRED, [nil, ERROR], [false, true], %w[retained released]).each do |phase, desired, error, stalled, archive|
      current = status(phase:, desired_state: desired, error:, stalled:, archive: { "state" => archive },
        cutover_at: at(86_400))
      result = LiteHM::OperationSummary.new(current, now: NOW)
      context = [phase, desired, error && "error", stalled && "stalled", archive].compact.join("/")

      assert LiteHM::OperationSummary::STATES.key?(result.state), context
      assert_equal previous_actions(current).sort, result.actions.sort, context
      assert_includes(-1..6, result.step, context)
      assert_kind_of String, result.status_line, context
      assert_kind_of String, result.header_line, context
      assert(result.primary_action.nil? || result.actions.include?(result.primary_action), context)
      if error && !current.terminal?
        assert_equal "Failed", result.label, context
        refute_includes result.status_line, "aused", context
      end
    end
  end

  def test_plain_language_states
    assert_equal :waiting, summary(phase: "planned", desired_state: "paused").state
    assert_equal "Start", summary(phase: "planned", desired_state: "paused").action_label("resume")
    assert_equal :queued, summary(phase: "planned").state
    assert_equal :paused, summary(desired_state: "paused").state
    assert_equal "Resume", summary(desired_state: "paused").action_label("resume")
    assert_equal :ready, summary(phase: "ready", policy: { "cutover" => "manual" }).state
    assert_equal "cutover", summary(phase: "ready", policy: { "cutover" => "manual" }).primary_action
    assert_equal :running, summary(phase: "ready").state
    assert_equal :cutting_over, summary(phase: "ready", desired_state: "cutover_requested").state
    assert_equal :failed, summary(desired_state: "paused", error: ERROR).state
    assert_equal :failed, summary(error: ERROR, stalled: true).state
    assert_equal %w[retry], summary(error: ERROR, stalled: true).actions
    assert_equal :stalled, summary(stalled: true).state
    assert_equal :live_archive, summary(phase: "cut_over", archive: { "state" => "retained" }).state
    assert_equal "cleanup", summary(phase: "cut_over", archive: { "state" => "retained" }).primary_action
    assert_equal :releasing, summary(phase: "cut_over", desired_state: "cleanup_requested", archive: { "state" => "retained" }).state
    assert_equal :done, summary(phase: "done").state
    assert_equal :aborted, summary(phase: "aborted", error: ERROR).state
  end

  def test_copy_progress_estimate_and_eta
    progress = { "copy_cursor" => integer(427), "copy_lower_bound" => integer(1),
      "copy_upper_bound" => integer(1_000), "copied_rows" => 427,
      "telemetry" => { "stage" => "copy", "stages" => { "copy" => { "rows_per_second" => 50.0 } } } }
    running = summary(progress:)

    assert_equal 0, running.step
    assert_in_delta 42.7, running.percent
    assert_equal 1_000, running.total_rows
    assert running.total_estimated?
    assert_equal 11, running.eta_seconds
    assert_equal "42.7% · 50 rows/s · ~11 s left", running.status_line
    assert_nil summary(progress:, desired_state: "paused").eta_seconds
    assert_equal "Paused at 42.7% · 3 s ago", summary(progress:, desired_state: "paused").status_line
  end

  def test_old_progress_without_new_fields_degrades_to_unknown
    legacy = summary(progress: { "copy_cursor" => integer(500), "copy_upper_bound" => integer(1_000),
      "copied_rows" => 500, "dirty_rows" => 251 })

    assert_nil legacy.percent
    assert_nil legacy.total_rows
    assert_nil legacy.eta_seconds
    assert_equal "500 rows copied", legacy.status_line
    assert_equal({}, legacy.worker_metrics)
    assert_equal "Schema change", summary(intent: nil).change_summary
    assert_equal "—", summary(phase: "cut_over", cutover_at: nil).short_date(nil)
  end

  def test_non_integer_keys_and_empty_tables
    text_keys = summary(progress: { "copy_cursor" => [{ "type" => "text", "value" => "m" }],
      "copy_lower_bound" => [{ "type" => "text", "value" => "a" }],
      "copy_upper_bound" => [{ "type" => "text", "value" => "z" }], "copied_rows" => 10 })
    assert_nil text_keys.percent
    assert_equal 0, text_keys.step

    empty = summary(progress: { "copy_cursor" => nil, "copy_upper_bound" => nil, "copied_rows" => 0 })
    assert_equal 100, empty.percent
    assert_equal 1, empty.step
  end

  def test_step_follows_durable_progress_and_the_worker_stage
    copied = { "copy_cursor" => integer(1_000), "copy_lower_bound" => integer(1),
      "copy_upper_bound" => integer(1_000), "copied_rows" => 1_000 }
    assert_equal 1, summary(progress: copied).step
    assert_equal 2, summary(progress: copied.merge("validation_source_cursor" => integer(5))).step
    assert_equal 2, summary(progress: copied.merge("telemetry" => { "stage" => "readiness" })).step
    assert_equal 3, summary(phase: "ready").step
    assert_equal 4, summary(phase: "ready", desired_state: "cutover_requested").step
    assert_equal 5, summary(phase: "cut_over").step
    assert_equal 6, summary(phase: "done").step
    assert_equal(-1, summary(phase: "planned").step)
    assert_equal :waiting, summary(phase: "ready", policy: { "cutover" => "manual" }).node_state(3)
    assert_equal :hold, summary(phase: "cut_over", archive: { "state" => "retained" }).node_state(5)
  end

  def test_change_summary_reads_the_recorded_intent
    intent = [
      ["add_column", "delivered", "boolean", { "null" => false, "default" => false }],
      ["add_index", %w[delivered sent_at], { "name" => "messages_delivery" }],
      ["change_column_null", "body", false, nil]
    ]
    result = summary(intent:)

    assert_equal "Add column delivered + add index on (delivered, sent_at) + 1 more", result.change_summary
    assert_equal ["Add column delivered (boolean, not null, default false)",
      "Add index on (delivered, sent_at)", "Make body NOT NULL"], result.changes
    assert_equal "Revert 20260910-users", summary(intent: [["revert", "20260910-users"]]).change_summary
    assert_equal "Add unique index on (email)", summary(intent: [["add_index", ["email"], { "unique" => true }]]).change_summary
  end

  def test_errors_become_one_plain_line
    failed = summary(error: ERROR, desired_state: "paused")
    assert_equal "Copy failed · NULL country_code", failed.status_line
    assert_equal "Some rows have NULL country_code, which the new schema forbids. Fix the data, then retry.", failed.error_line

    unique = summary(error: { "class" => "LiteHM::DataIncompatible", "message" => "x",
      "details" => { "sqlite_error" => "UNIQUE constraint failed: __litehm_shadow_1.email, __litehm_shadow_1.tenant_id" } })
    assert_equal "duplicate (email, tenant_id)", unique.error_cause

    generic = summary(error: { "class" => "LiteHM::BusyBudgetExceeded", "message" => "ready budgets exhausted in __litehm_dirty_abc" })
    assert_equal "BusyBudgetExceeded: ready budgets exhausted in the shadow table", generic.error_line
    assert_equal "Copy failed · BusyBudgetExceeded", generic.status_line
  end

  def test_compact_durations
    assert_equal "4 s", LiteHM::OperationSummary.compact_duration(4)
    assert_equal "47 m", LiteHM::OperationSummary.compact_duration(47 * 60)
    assert_equal "1 h 37 m", LiteHM::OperationSummary.compact_duration(97 * 60)
    assert_equal "3 h", LiteHM::OperationSummary.compact_duration(3 * 3_600)
    assert_equal "7 d", LiteHM::OperationSummary.compact_duration(7 * 86_400)
  end

  def test_sort_puts_what_needs_an_operator_first
    summaries = [summary(phase: "done"), summary, summary(error: ERROR), summary(phase: "planned", desired_state: "paused")]
    assert_equal %i[failed waiting running done], LiteHM::OperationSummary.sort(summaries).map(&:state)
  end
end
