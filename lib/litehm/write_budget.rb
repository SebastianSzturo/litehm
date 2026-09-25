# frozen_string_literal: true

module LiteHM
  # Shared scheduling for the single SQLite writer. A duration is feedback for
  # the NEXT batch, never a claim that COMMIT or one SQLite row is interruptible.
  class WriteBudget
    attr_reader :row_limit, :target_ms, :byte_limit, :max_row_bytes

    def initialize(policy)
      @target_ms = policy.fetch("writer_lease_ms")
      @byte_limit = policy.fetch("max_batch_bytes", 256 * 1024)
      @max_row_bytes = policy.fetch("max_row_bytes", 16 * 1024 * 1024)
      @duty_cycle = policy.fetch("writer_duty_cycle", 0.25)
      @pause_ms = policy.fetch("min_batch_pause_ms", 10)
      @row_limit = 16
    end

    def observe(rows, elapsed_ms)
      return unless rows && rows.positive?

      # Shrink immediately; grow gradually. Starting small also applies after a
      # process restart, where timing learned by the dead worker is unavailable.
      suggested = (rows * target_ms * 0.7 / [elapsed_ms, 0.1].max).floor
      @row_limit = [[suggested, 1].max, [row_limit * 2, 250].min].min
    end

    def pause_seconds(elapsed_ms, floor: true)
      [floor ? @pause_ms : 0, elapsed_ms * (1.0 / @duty_cycle - 1)].max / 1000.0
    end
  end
end
