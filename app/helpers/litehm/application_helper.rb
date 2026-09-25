# frozen_string_literal: true

module LiteHM
  module ApplicationHelper
    def litehm_phase_class(status)
      return "danger" if status.error || status.stalled?
      return "muted" if status.paused?
      return "success" if status.cut_over? || status.terminal?

      "active"
    end

    STAGES = {
      "preparing" => "Preparation", "copy" => "Copy", "reconcile" => "Reconciliation",
      "validate_source" => "Source validation", "validate_target" => "Target validation",
      "readiness" => "Readiness", "cutover" => "Cutover", "cleanup" => "Cleanup",
      "abort" => "Abort", "capture_repair" => "Capture repair"
    }.freeze
    REASONS = {
      "operator_pause" => "Paused by an operator", "operation_error" => "Stopped after an error",
      "awaiting_cutover" => "Awaiting cutover", "abort_requested" => "Abort requested",
      "cleanup_requested" => "Cleanup requested", "cutover_requested" => "Cutover requested",
      "writer_duty_cycle" => "Yielding time to application writers", "writer_lock" => "Writer lock contention",
      "cutover_lock" => "Cutover lock contention", "cutover_budget" => "Cutover time budget exceeded",
      "cutover_tail" => "Draining changes before cutover", "ready_tail" => "Draining changes before readiness",
      "target_constraint" => "Reconciling a target constraint conflict", "capture_lost" => "Repairing capture artifacts",
      "lease_conflict" => "Waiting for the execution lease", "job_busy" => "Retrying a busy database"
    }.freeze

    def litehm_stage(value)
      STAGES.fetch(value, value.to_s.humanize)
    end

    def litehm_reason(value)
      REASONS.fetch(value, value.to_s.humanize)
    end

    def litehm_dirty_rows(status)
      count = status.progress["dirty_rows"]
      return "Not sampled" if count.nil?

      number = number_with_delimiter(count)
      status.dirty_rows_exact? ? number : "At least #{number}"
    end

    def litehm_metric(value, unit: nil)
      return "—" if value.nil?

      [number_with_precision(value, precision: 2, strip_insignificant_zeros: true, delimiter: ","), unit].compact.join(" ")
    end

    def litehm_time(value)
      value ? Time.iso8601(value).utc.strftime("%Y-%m-%d %H:%M:%S UTC") : "—"
    rescue ArgumentError
      value
    end
  end
end
