# frozen_string_literal: true

require "rails"
require "securerandom"

module LiteHM
  # A bounded, per-execution summary for the engine. Rails owns event delivery,
  # subscription, filtering, and error reporting; this is not an event store.
  class Telemetry
    INTERVAL_SECONDS = 5.0
    DEBUG_EVENTS = %w[litehm.batch litehm.checkpoint litehm.throttle_changed].freeze

    def self.emit(name, payload, debug: false)
      Rails.event.public_send(debug ? :debug : :notify, "litehm.#{name}", payload, caller_depth: 2)
    rescue StandardError => error
      # A subscriber must never turn an already committed migration into a
      # failure, even when Rails.event.raise_on_error is enabled locally.
      begin
        Rails.error.report(error, handled: true, source: "litehm.telemetry")
      rescue StandardError
        nil
      end
    end

    class LogSubscriber
      def emit(event)
        return unless LiteHM.configuration.log_events && Rails.logger
        return if DEBUG_EVENTS.include?(event[:name])

        level = %w[litehm.failed litehm.enqueue_failed].include?(event[:name]) ? :error : :info
        Rails.logger.public_send(level) do
          JSON.generate(event.slice(:name, :payload, :timestamp))
        end
      end
    end

    attr_reader :execution_id

    def initialize(plan, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @identity = { version: 1, plan_id: plan.id, table: plan.table }
      @clock = clock
      @execution_id = SecureRandom.uuid
      @started = now
      @started_at = timestamp
      @stage_started = @started
      @stage = "preparing"
      @stages = {}
      @lock_wait_ms = 0.0
      @lock_retries = @rollbacks = 0
      @saved_at = @published_at = nil
      @snapshot_requested = true
    end

    def stage=(value)
      value = value.to_s
      return if value == @stage

      accrue_stage_time
      @stage = value
      @stage_started = now
      @snapshot_requested = true
    end

    def batch(kind:, rows:, transaction_ms:, lock_wait_ms:, committed:, next_rows:, previous_rows:, pause_ms:)
      @lock_wait_ms += lock_wait_ms
      @rollbacks += 1 unless committed
      values = stage_totals
      if committed
        values["rows"] += rows.to_i
        values["batches"] += 1
      end
      values["transaction_ms"] += transaction_ms
      values["max_transaction_ms"] = [values["max_transaction_ms"], transaction_ms].max
      batch = {
        "kind" => kind.to_s, "rows" => committed ? rows.to_i : 0, "committed" => committed,
        "transaction_ms" => rounded(transaction_ms), "lock_wait_ms" => rounded(lock_wait_ms),
        "next_rows" => next_rows, "pause_ms" => rounded(pause_ms), "pause_reason" => "writer_duty_cycle"
      }
      @last_batch = batch unless kind == :control
      emit("batch", batch, debug: true)
      if next_rows != previous_rows
        emit("throttle_changed", { previous_rows:, next_rows:, pause_ms: rounded(pause_ms),
          reason: "transaction_duration" }, debug: true)
      end
    end

    def validated(rows)
      stage_totals["rows"] += rows
    end

    def waited(milliseconds)
      @lock_wait_ms += milliseconds
    end

    def retrying(reason:, attempt: nil, wait_ms: nil, error: nil, lock_wait_ms: 0)
      @lock_wait_ms += lock_wait_ms
      @lock_retries += 1 if %w[writer_lock cutover_lock].include?(reason)
      @last_retry = { "reason" => reason, "attempt" => attempt,
        "wait_ms" => wait_ms, "error_class" => error&.class&.name, "at" => timestamp }.compact
      emit("retry", @last_retry)
    end

    def checkpoint(result:, elapsed_ms:)
      busy, log, copied = result || []
      known = log && copied && log >= 0 && copied >= 0
      @checkpoint = {
        "sampled_at" => timestamp, "duration_ms" => rounded(elapsed_ms),
        "status" => known ? "sampled" : "unavailable", "busy" => busy,
        "log_frames" => known ? log : nil, "checkpointed_frames" => known ? copied : nil,
        "pending_frames" => known ? [log - copied, 0].max : nil
      }
      emit("checkpoint", @checkpoint, debug: true)
    end

    def request_snapshot!
      @snapshot_requested = true
    end

    def snapshot_due?
      @snapshot_requested || !@saved_at || now - @saved_at >= INTERVAL_SECONDS
    end

    def saved!
      @saved_at = now
      @snapshot_requested = false
    end

    def snapshot
      stages = @stages.transform_values(&:dup)
      stages[@stage] ||= empty_stage
      stages[@stage]["elapsed_ms"] += (now - @stage_started) * 1_000
      stages.each_value do |values|
        seconds = values["elapsed_ms"] / 1_000.0
        values["rows_per_second"] = seconds.positive? ? rounded(values["rows"] / seconds) : nil
        values.transform_values! { |value| value.is_a?(Float) ? rounded(value) : value }
      end
      {
        "version" => 1, "execution_id" => execution_id, "started_at" => @started_at,
        "sampled_at" => timestamp, "stage" => @stage, "elapsed_ms" => rounded((now - @started) * 1_000),
        "stages" => stages, "lock_wait_ms" => rounded(@lock_wait_ms), "lock_retries" => @lock_retries,
        "rollbacks" => @rollbacks, "last_batch" => @last_batch&.dup,
        "last_retry" => @last_retry&.dup, "checkpoint" => @checkpoint&.dup
      }
    end

    def publish(status, force: false)
      state = [status.phase, status.desired_state]
      if @last_state != state
        emit("state_changed", { phase: status.phase, desired_state: status.desired_state,
          pause_reason: status.pause_reason })
        @last_state = state
        force = true
      end
      return unless force || !@published_at || now - @published_at >= INTERVAL_SECONDS

      emit("progress", { phase: status.phase, desired_state: status.desired_state,
        copied_rows: status.progress["copied_rows"], dirty_rows: status.progress["dirty_rows"],
        dirty_rows_exact: status.dirty_rows_exact?, pause_reason: status.pause_reason, telemetry: snapshot })
      @published_at = now
    end

    def failed(error)
      emit("failed", { error_class: error.class.name, stage: @stage })
    end

    private

    def emit(name, payload, debug: false)
      self.class.emit(name, @identity.merge(execution_id:, **payload.transform_keys(&:to_sym)), debug:)
    end

    def stage_totals
      @stages[@stage] ||= empty_stage
    end

    def empty_stage
      { "rows" => 0, "batches" => 0, "elapsed_ms" => 0.0,
        "transaction_ms" => 0.0, "max_transaction_ms" => 0.0 }
    end

    def accrue_stage_time
      stage_totals["elapsed_ms"] += (now - @stage_started) * 1_000
    end

    def now
      @clock.call
    end

    def timestamp
      Time.now.utc.iso8601(6)
    end

    def rounded(value)
      value.round(3)
    end
  end
end
