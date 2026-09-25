# frozen_string_literal: true

module LiteHM
  module ApplicationHelper
    STAGES = {
      "preparing" => "Preparation", "copy" => "Copy", "reconcile" => "Catch up",
      "validate_source" => "Source validation", "validate_target" => "Target validation",
      "readiness" => "Readiness", "cutover" => "Cutover", "cleanup" => "Cleanup",
      "abort" => "Abort", "capture_repair" => "Capture repair"
    }.freeze
    REASONS = {
      "operator_pause" => "Paused by an operator", "operation_error" => "Stopped after an error",
      "awaiting_start" => "Waiting to be started",
      "awaiting_cutover" => "Awaiting cutover", "abort_requested" => "Abort requested",
      "cleanup_requested" => "Cleanup requested", "cutover_requested" => "Cutover requested",
      "writer_duty_cycle" => "Yielding to app writers", "writer_lock" => "Writer lock contention",
      "cutover_lock" => "Cutover lock contention", "cutover_budget" => "Cutover time budget exceeded",
      "cutover_tail" => "Draining changes before cutover", "ready_tail" => "Draining changes before readiness",
      "target_constraint" => "Reconciling a target constraint conflict", "capture_lost" => "Repairing capture artifacts",
      "lease_conflict" => "Waiting for the execution lease", "job_busy" => "Retrying a busy database"
    }.freeze
    ARCHIVE_STATES = { "retained" => "kept", "releasing" => "releasing", "released" => "released" }.freeze

    def litehm_summary(status, now: Time.now.utc)
      OperationSummary.new(status, now:)
    end

    def litehm_chip(summary)
      tag.span(summary.label, class: "chip tone-#{summary.tone}")
    end

    # "2 need you · 1 running · 1 paused · 5 done", skipping zero counts.
    def litehm_counts(summaries)
      counts = [
        [summaries.count(&:needs_you?), "need you", "attn"],
        [summaries.count(&:active?), "running", nil],
        [summaries.count { |summary| summary.state == :paused }, "paused", nil],
        [summaries.count(&:finished?), "done", nil]
      ].reject { |count, _label, _css| count.zero? }
      safe_join(counts.map { |count, label, css| tag.span("#{count} #{label}", class: css) }, " · ")
    end

    def litehm_action_button(summary, command, primary: false)
      classes = []
      classes << "primary" if primary
      classes << "danger" if summary.dangerous?(command)
      form = { class: "action" }
      if (message = summary.action_confirm(command))
        form[:data] = { litehm_confirm: message }
      end
      button_to summary.action_label(command), command_operation_path(summary.plan_id),
        params: { operation_command: command }, class: classes.join(" ").presence,
        title: summary.action_tip(command), form:
    end

    # Fill of the connector after step `index` on the track, in percent.
    def litehm_track_fill(summary, index)
      node = summary.node_state(index)
      return 100 if node == :done
      return summary.percent if index.zero? && %i[current paused failed].include?(node) && summary.percent

      0
    end

    def litehm_track_note(summary, index, detailed)
      case summary.node_state(index)
      when :current
        if index.nonzero? then "now"
        elsif summary.percent then "#{summary.percent}%"
        else "copying"
        end
      when :paused then index.zero? && summary.percent ? "paused #{summary.percent}%" : "paused"
      when :failed then "failed"
      when :stalled then "stalled"
      when :waiting then "waiting"
      when :hold then "archive kept"
      when :stopped then "aborting"
      when :done
        detailed && index == 4 && summary.cutover_time ? summary.short_date(summary.cutover_time) : ""
      else ""
      end
    end

    def litehm_stage(value)
      STAGES.fetch(value, value.to_s.humanize)
    end

    def litehm_reason(value)
      REASONS.fetch(value, value.to_s.humanize)
    end

    def litehm_archive_state(status)
      ARCHIVE_STATES.fetch(status.archive.to_h["state"], "—")
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

    # "08:45 UTC" today, otherwise the full litehm_time.
    def litehm_clock(time, now: Time.now.utc)
      time.utc.to_date == now.to_date ? time.utc.strftime("%H:%M UTC") : litehm_time(time, now:)
    end

    def litehm_ago(summary, value)
      value ? "#{summary.duration_since(value)} ago" : "—"
    end

    # "Sep 25, 08:46 UTC"; the year only when it differs from now.
    def litehm_time(value, now: Time.now.utc)
      return "—" unless value

      time = value.is_a?(Time) ? value.utc : Time.iso8601(value.to_s).utc
      time.strftime(time.year == now.year ? "%b %-d, %H:%M UTC" : "%b %-d %Y, %H:%M UTC")
    rescue ArgumentError
      value
    end
  end
end
