# frozen_string_literal: true

module LiteHM
  class Status
    ATTRIBUTES = %i[
      plan_id table phase source_hash target_hash error progress archive retry_action
      desired_state execution_revision last_advanced_at created_at updated_at
      stalled recovery_enqueued_at
    ].freeze

    attr_reader(*ATTRIBUTES)

    def self.missing(plan_id)
      new(plan_id: plan_id, table: nil, phase: "missing", source_hash: nil,
        target_hash: nil, error: nil, progress: {}, archive: {}, retry_action: "forbidden",
        desired_state: "stopped", execution_revision: 0, last_advanced_at: nil,
        created_at: nil, updated_at: nil, stalled: false, recovery_enqueued_at: nil)
    end

    def initialize(**attributes)
      ATTRIBUTES.each { |key| instance_variable_set("@#{key}", attributes.fetch(key)) }
      freeze
    end

    def ready?
      phase == "ready"
    end

    def cut_over?
      %w[cut_over archive_released done].include?(phase)
    end

    def missing?
      phase == "missing"
    end

    def terminal?
      %w[done aborted].include?(phase)
    end

    def paused?
      desired_state == "paused"
    end

    # Still wants worker time, but no runner holds the writer lease and nothing
    # has been committed for LiteHM.configuration.stalled_after seconds —
    # typically a worker killed without a graceful stop.
    def stalled?
      stalled == true
    end

    def telemetry
      progress.fetch("telemetry", {})
    end

    def dirty_rows_exact?
      return nil unless progress.key?("dirty_rows")
      return progress["dirty_rows_exact"] if progress.key?("dirty_rows_exact")

      # Older plans sampled at 251 without recording the cap explicitly.
      progress["dirty_rows"] < 251
    end

    def pause_reason
      return "operation_error" if error && !terminal?
      return "awaiting_start" if paused? && phase == "planned"
      return "operator_pause" if paused?
      return "awaiting_cutover" if ready? && desired_state == "running"
      return desired_state if %w[abort_requested cleanup_requested cutover_requested].include?(desired_state)

      nil
    end

    def to_h
      ATTRIBUTES.to_h { |attribute| [attribute, public_send(attribute)] }
    end
  end
end
