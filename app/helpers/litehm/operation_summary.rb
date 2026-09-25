# frozen_string_literal: true

require "active_support/number_helper"

module LiteHM
  # Plain-language reading of one Status for the engine: which state it is in,
  # where it is on the copy → cleanup track, a progress estimate, and which
  # commands the Status allows. Pure Ruby over already-stored data.
  class OperationSummary
    STEPS = ["Copy", "Catch up", "Validate", "Ready", "Cut over", "Clean up"].freeze

    # state => [label, tone]
    STATES = {
      failed: ["Failed", "danger"], stalled: ["Stalled", "warning"],
      waiting: ["Waiting to start", "attention"], ready: ["Ready to cut over", "attention"],
      queued: ["Queued", "info"], running: ["Running", "info"],
      cutting_over: ["Cutting over", "info"], releasing: ["Releasing archive", "info"],
      aborting: ["Aborting", "muted"], paused: ["Paused", "muted"],
      live_archive: ["Live · archive kept", "success"], live: ["Live", "success"],
      done: ["Done", "success"], aborted: ["Aborted", "muted"]
    }.freeze
    NEEDS_YOU = %i[failed stalled waiting ready].freeze
    FINISHED = %i[live_archive live done aborted].freeze
    ACTIVE = %i[queued running cutting_over releasing aborting].freeze
    URGENCY = %i[failed stalled ready waiting paused running cutting_over queued releasing
      aborting live_archive live done aborted].freeze
    PRIMARY = { failed: "retry", stalled: "retry", waiting: "resume", paused: "resume",
      ready: "cutover", live_archive: "cleanup" }.freeze
    DANGEROUS = %w[abort cleanup].freeze
    CONFIRM = {
      "cutover" => "Cut over now? This swaps in the new table.",
      "abort" => "Abort this migration? The shadow table is dropped.",
      "cleanup" => "Release the archive? The old table is deleted."
    }.freeze
    TIPS = {
      "resume" => "Continues from the last saved row", "pause" => "Stops at the next safe point",
      "retry" => "Runs the failed or stalled step again",
      "cutover" => "Atomic swap; undo needs a revert migration",
      "abort" => "Drops the shadow table; the table stays unchanged",
      "cleanup" => "Deletes the old table; cannot be undone"
    }.freeze
    VALIDATION_STAGES = %w[validate_source validate_target readiness].freeze
    VALIDATION_KEYS = %w[validation_source_cursor validation_target_cursor].freeze

    attr_reader :status, :now

    def initialize(status, now: Time.now.utc)
      @status = status
      @now = now
    end

    def self.sort(summaries)
      summaries.sort_by.with_index { |summary, index| [URGENCY.index(summary.state), index] }
    end

    def plan_id = status.plan_id
    def table = status.table

    def state
      @state ||= begin
        phase = status.phase
        if status.error && !status.terminal? then :failed
        elsif phase == "aborted" then :aborted
        elsif phase == "done" then :done
        elsif status.stalled? then :stalled
        else
          case phase
          when "planned"
            if status.paused? then :waiting
            elsif status.desired_state == "abort_requested" then :aborting
            else :queued
            end
          when "preparing", "ready" then preparing_state
          when "aborting" then :aborting
          when "cut_over"
            if status.desired_state == "cleanup_requested" then :releasing
            elsif status.archive.to_h["state"] == "retained" then :live_archive
            else :live
            end
          when "archive_released" then :releasing
          else :running
          end
        end
      end
    end

    def label = STATES.fetch(state).first
    def tone = STATES.fetch(state).last
    def needs_you? = NEEDS_YOU.include?(state)
    def finished? = FINISHED.include?(state)
    def active? = ACTIVE.include?(state)

    # 0..5 is the current step on the track, -1 is not started, 6 is all done.
    def step
      @step ||= case status.phase
      when "planned" then -1
      when "preparing", "aborting", "aborted" then preparing_step
      when "ready" then status.desired_state == "cutover_requested" ? 4 : 3
      when "cut_over", "archive_released" then 5
      when "done" then 6
      else -1
      end
    end

    def step_name
      step.between?(0, 5) ? STEPS.fetch(step) : "Start"
    end

    # :done, :pending, or how the current step is going.
    def node_state(index)
      return :done if index < step
      return :pending if index > step

      case state
      when :failed then :failed
      when :stalled then :stalled
      when :paused then :paused
      when :ready then :waiting
      when :live_archive then :hold
      when :aborting, :aborted then :stopped
      else :current
      end
    end

    def copied_rows
      status.progress.fetch("copied_rows", 0).to_i
    end

    # Key-range fraction of the copy for single integer keys; nil when unknown.
    def copy_fraction
      return @copy_fraction if defined?(@copy_fraction)

      @copy_fraction = if step.negative? then nil
      elsif step >= 1 then 1.0
      elsif status.progress.key?("copy_upper_bound") && status.progress["copy_upper_bound"].nil? then 1.0
      else key_range_fraction
      end
    end

    # 42.7, or 61 when the decimal would be .0.
    def percent
      return nil unless copy_fraction

      value = (copy_fraction * 100).round(1)
      value == value.round ? value.round : value
    end

    def total_rows
      return copied_rows if step >= 1
      return nil unless copy_fraction && copy_fraction >= 0.001 && copied_rows.positive?

      (copied_rows / copy_fraction).round
    end

    def total_estimated?
      step < 1
    end

    # Copy rate from the worker sample; only meaningful while it is copying.
    def copy_rate
      return nil unless state == :running && step.zero?

      rate = stage_metrics("copy")["rows_per_second"]
      rate.is_a?(Numeric) && rate.positive? ? rate : nil
    end

    def eta_seconds
      return nil unless copy_rate && total_rows && total_rows > copied_rows

      ((total_rows - copied_rows) / copy_rate).round
    end

    def eta_at
      eta_seconds && now + eta_seconds
    end

    def actions
      @actions ||= begin
        list = []
        if status.error && !status.terminal?
          list << "retry"
        else
          list << "retry" if status.stalled?
          if %w[planned preparing ready].include?(status.phase)
            list << (status.paused? ? "resume" : "pause")
            list << "cutover" if status.ready?
            list << "abort"
          end
        end
        list << "cleanup" if status.cut_over? && status.archive.to_h["state"] == "retained"
        list.uniq
      end
    end

    def primary_action
      candidate = PRIMARY[state]
      candidate if actions.include?(candidate)
    end

    # Primary first, destructive last.
    def ordered_actions
      actions.sort_by { |command| [command == primary_action ? 0 : 1, DANGEROUS.include?(command) ? 1 : 0] }
    end

    def action_label(command)
      case command
      when "resume" then status.phase == "planned" ? "Start" : "Resume"
      when "pause" then "Pause"
      when "retry" then "Retry"
      when "cutover" then "Cut over"
      when "abort" then "Abort"
      when "cleanup" then "Release archive"
      else command.to_s.humanize
      end
    end

    def action_tip(command)
      command == "resume" && status.phase == "planned" ? "Starts copying in the background" : TIPS[command]
    end

    def action_confirm(command) = CONFIRM[command]
    def dangerous?(command) = DANGEROUS.include?(command)

    def changes
      Array(status.intent).map { |operation| describe(operation) }
    end

    def change_summary
      list = Array(status.intent).map { |operation| describe(operation, short: true) }
      return "Schema change" if list.empty?

      text = list.first(2).join(" + ")
      text += " + #{list.length - 2} more" if list.length > 2
      text[0].upcase + text[1..]
    end

    # One short line for cards and the detail header.
    def status_line
      case state
      when :failed then "#{step_name} failed · #{error_cause}"
      when :stalled then "No progress for #{duration_since(last_activity)}"
      when :waiting then "Not started · added #{duration_since(status.created_at)} ago"
      when :queued then "Waiting for a worker"
      when :running then running_line
      when :paused then paused_line
      when :ready then "Ready #{duration_since(status.last_advanced_at || status.updated_at)} · manual cutover"
      when :cutting_over then "Cutover requested"
      when :releasing then "Releasing the old table"
      when :aborting then "Dropping the shadow table"
      when :live_archive then "Live since #{short_date(cutover_time)} · old table kept"
      when :live then "Live since #{short_date(cutover_time)}"
      when :done then "Live since #{short_date(cutover_time)} · archive released"
      when :aborted then "Aborted #{short_date(status.updated_at)}"
      end
    end

    def header_line
      case state
      when :failed then "#{step_name} failed #{duration_since(status.updated_at)} ago"
      when :stalled then "Last commit #{duration_since(last_activity)} ago"
      else status_line
      end
    end

    def error_cause
      return unless status.error

      case error_text
      when /NOT NULL constraint failed: (?:\S+\.)?(\w+)/ then "NULL #{Regexp.last_match(1)}"
      when /UNIQUE constraint failed: ([^\n]+)/ then "duplicate (#{constraint_columns(Regexp.last_match(1))})"
      when /CHECK constraint failed: (\S+)/ then "check #{Regexp.last_match(1)} fails"
      when /FOREIGN KEY constraint failed/ then "foreign key violation"
      else error_class_name
      end
    end

    # One plain sentence; the raw error stays available behind <details>.
    def error_line
      return unless status.error

      case error_text
      when /NOT NULL constraint failed: (?:\S+\.)?(\w+)/
        "Some rows have NULL #{Regexp.last_match(1)}, which the new schema forbids. Fix the data, then retry."
      when /UNIQUE constraint failed: ([^\n]+)/
        "Rows share the same (#{constraint_columns(Regexp.last_match(1))}), which the new schema forbids. Fix the data, then retry."
      when /CHECK constraint failed: (\S+)/
        "Rows fail check #{Regexp.last_match(1)}. Fix the data, then retry."
      when /FOREIGN KEY constraint failed/
        "Rows violate a foreign key. Fix the data, then retry."
      else
        "#{error_class_name}: #{scrub(status.error["message"].to_s.lines.first.to_s.strip)}"
      end
    end

    def stalled_line
      "No commit for #{duration_since(last_activity)} and no worker holds the lease. Check the #{LiteHM.configuration.queue_name} worker, then retry."
    end

    def last_activity
      [status.last_advanced_at, status.updated_at].compact.max
    end

    def cutover_time
      status.cutover_at
    end

    def worker_metrics
      status.telemetry
    end

    def max_transaction_ms
      values = worker_metrics.fetch("stages", {}).values.map { |stage| stage["max_transaction_ms"] }.grep(Numeric)
      values.max
    end

    # "4 s", "47 m", "1 h 37 m", "7 d".
    def self.compact_duration(seconds)
      seconds = seconds.to_i
      return "#{seconds} s" if seconds < 60
      return "#{seconds / 60} m" if seconds < 3_600

      hours, minutes = (seconds / 60).divmod(60)
      return(minutes.zero? ? "#{hours} h" : "#{hours} h #{minutes} m") if hours < 48

      "#{hours / 24} d"
    end

    def duration_since(timestamp)
      time = parse_time(timestamp)
      time ? self.class.compact_duration([now - time, 0].max) : "—"
    end

    def short_date(timestamp)
      time = parse_time(timestamp)
      return "—" unless time

      time.year == now.year ? time.strftime("%b %-d") : time.strftime("%b %-d, %Y")
    end

    def parse_time(value)
      value && Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end

    private

    def preparing_state
      return :aborting if status.desired_state == "abort_requested"
      return :paused if status.paused?
      return :cutting_over if status.desired_state == "cutover_requested"
      return :ready if status.ready? && status.policy.to_h["cutover"] == "manual"

      :running
    end

    # Durable progress first, refined by the last worker sample's stage.
    def preparing_step
      stage = worker_metrics["stage"].to_s
      return 2 if VALIDATION_STAGES.include?(stage) || VALIDATION_KEYS.any? { |key| status.progress.key?(key) }

      fraction = key_range_fraction
      copy_complete = status.progress.key?("copy_upper_bound") && status.progress["copy_upper_bound"].nil?
      copy_complete ||= fraction && fraction >= 1.0
      return 1 if copy_complete
      return 1 if stage == "reconcile" && fraction.nil? && copied_rows.positive?

      0
    end

    def key_range_fraction
      progress = status.progress
      lower = single_integer(progress["copy_lower_bound"])
      upper = single_integer(progress["copy_upper_bound"])
      return nil unless lower && upper && upper >= lower
      return 0.0 if progress["copy_cursor"].nil?

      cursor = single_integer(progress["copy_cursor"])
      return nil unless cursor

      ((cursor - lower + 1).to_f / (upper - lower + 1)).clamp(0.0, 1.0)
    end

    def single_integer(encoded)
      return nil unless encoded.is_a?(Array) && encoded.length == 1

      value = encoded.first
      value.is_a?(Hash) && value["type"] == "integer" ? value["value"] : nil
    end

    def running_line
      case step
      when 0
        parts = []
        parts << "#{percent}%" if percent
        parts << "#{delimit(copy_rate.round)} rows/s" if copy_rate
        parts << "~#{self.class.compact_duration(eta_seconds)} left" if eta_seconds
        parts << "#{delimit(copied_rows)} rows copied" if percent.nil?
        parts.join(" · ")
      when 1 then "Catching up on changes"
      when 2 then "Validating rows"
      when 3 then "Ready · cutting over"
      else "Running"
      end
    end

    def paused_line
      where = step.zero? && percent ? "at #{percent}%" : "during #{step_name.downcase}"
      "Paused #{where} · #{duration_since(status.updated_at)} ago"
    end

    def stage_metrics(name)
      worker_metrics.fetch("stages", {}).fetch(name, {})
    end

    def describe(operation, short: false)
      name, *arguments = operation
      options = arguments.last.is_a?(Hash) ? arguments.last : {}
      case name
      when "add_column"
        column, type = arguments
        details = [type]
        details << "not null" if options["null"] == false
        details << "default #{options["default"].inspect}" if options.key?("default")
        short ? "add column #{column}" : "Add column #{column} (#{details.join(', ')})"
      when "remove_column" then "#{verb('remove', short)} column #{arguments.first}"
      when "change_column" then "#{verb('change', short)} column #{arguments[0]} to #{arguments[1]}"
      when "change_column_default" then "#{verb('change', short)} default of #{arguments.first}"
      when "change_column_null"
        arguments[1] ? "#{verb('allow', short)} NULL #{arguments[0]}" : "#{verb('make', short)} #{arguments[0]} NOT NULL"
      when "rename_column" then "#{verb('rename', short)} column #{arguments[0]} to #{arguments[1]}"
      when "add_index"
        kind = options["unique"] ? "unique index" : "index"
        "#{verb('add', short)} #{kind} on (#{Array(arguments.first).join(', ')})"
      when "remove_index"
        target = options["name"] || "(#{Array(arguments.first).join(', ')})"
        "#{verb('remove', short)} index #{target}"
      when "rename_index" then "#{verb('rename', short)} index #{arguments[0]} to #{arguments[1]}"
      when "add_reference" then "#{verb('add', short)} reference #{arguments.first}"
      when "remove_reference" then "#{verb('remove', short)} reference #{arguments.first}"
      when "add_timestamps" then "#{verb('add', short)} timestamps"
      when "remove_timestamps" then "#{verb('remove', short)} timestamps"
      when "add_foreign_key" then "#{verb('add', short)} foreign key to #{arguments.first}"
      when "remove_foreign_key" then "#{verb('remove', short)} foreign key#{" to #{arguments.first}" if arguments.first.is_a?(String)}"
      when "add_check_constraint" then "#{verb('add', short)} check #{options['name'] || arguments.first}"
      when "remove_check_constraint" then "#{verb('remove', short)} check #{options['name']}".strip
      when "project" then "#{verb('set', short)} #{arguments.first} from an expression"
      when "ddl" then "#{verb('apply', short)} raw DDL"
      when "revert" then "#{verb('revert', short)} #{arguments.first}"
      else name.to_s.tr("_", " ")
      end
    end

    def verb(word, short)
      short ? word : word.capitalize
    end

    def error_text
      error = status.error.to_h
      [error.dig("details", "sqlite_error"), error["message"]].compact.join("\n")
    end

    def error_class_name
      status.error.to_h["class"].to_s.split("::").last || "Error"
    end

    def constraint_columns(list)
      list.split(",").map { |column| column.strip.split(".").last }.join(", ")
    end

    # Internal artifact names mean nothing to an operator.
    def scrub(text)
      text.gsub(/__litehm_\w+/, "the shadow table")
    end

    def delimit(number)
      ActiveSupport::NumberHelper.number_to_delimited(number)
    end
  end
end
