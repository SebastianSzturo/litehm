# frozen_string_literal: true

module LiteHM
  class Policy
    DEFAULTS = {
      writer_lease_ms: 10,
      max_batch_bytes: 256 * 1024,
      max_row_bytes: 16 * 1024 * 1024,
      writer_duty_cycle: 0.25,
      min_batch_pause_ms: 10,
      lease_ttl_ms: 30_000,
      cutover_acquire_ms: 1_000,
      cutover_hold_ms: 50,
      max_ready_batches: 10_000,
      max_cutover_attempts: 20,
      max_cutover_elapsed_ms: 300_000,
      busy_timeout_ms: 10_000,
      max_wal_bytes: nil,
      max_database_bytes: nil,
      archive: :retain,
      cutover: :automatic,
      source_replace_writes: false,
      parent_replace_writes: false,
      all_writers_recursive_triggers: false,
      allow_bare_rowid: false
    }.freeze

    # Pre-budget plans stored different timing defaults. Resume their original
    # policy, but distinguish a default change from an explicit caller override.
    LEGACY_TIMING_DEFAULTS = { "writer_lease_ms" => 75, "cutover_hold_ms" => 500 }.freeze
    BUDGET_KEYS = %w[max_batch_bytes max_row_bytes writer_duty_cycle min_batch_pause_ms].freeze

    def self.compatible?(stored, candidate, overrides: {})
      return true if stored == candidate
      return false unless BUDGET_KEYS.none? { |key| stored.key?(key) }

      defaults = CanonicalJSON.normalize(DEFAULTS)
      (stored.keys | candidate.keys).all? do |key|
        expected = stored.fetch(key) { defaults[key] }
        value = candidate[key]
        value == expected || (
          !overrides.key?(key) && LEGACY_TIMING_DEFAULTS.key?(key) &&
          expected == LEGACY_TIMING_DEFAULTS.fetch(key) && value == defaults.fetch(key)
        )
      end
    end

    attr_reader :values

    def initialize(**overrides)
      unknown = overrides.keys - DEFAULTS.keys
      raise ArgumentError, "unknown policy keys: #{unknown.join(', ')}" unless unknown.empty?

      @values = DEFAULTS.merge(overrides).freeze
      validate!
    end

    def [](key)
      values.fetch(key)
    end

    def to_h
      values
    end

    private

    def validate!
      %i[writer_lease_ms max_batch_bytes max_row_bytes min_batch_pause_ms lease_ttl_ms cutover_acquire_ms cutover_hold_ms max_ready_batches
        max_cutover_attempts max_cutover_elapsed_ms busy_timeout_ms].each do |key|
        value = values.fetch(key)
        raise ArgumentError, "#{key} must be positive" unless value.is_a?(Integer) && value.positive?
      end

      duty = values.fetch(:writer_duty_cycle)
      unless duty.is_a?(Numeric) && duty.finite? && duty.positive? && duty <= 0.5
        raise ArgumentError, "writer_duty_cycle must be greater than zero and at most 0.5"
      end

      unless %i[retain ephemeral].include?(values.fetch(:archive))
        raise ArgumentError, "archive must be :retain or :ephemeral"
      end
      unless %i[automatic manual].include?(values.fetch(:cutover))
        raise ArgumentError, "cutover must be :automatic or :manual"
      end

      %i[source_replace_writes parent_replace_writes all_writers_recursive_triggers allow_bare_rowid].each do |key|
        raise ArgumentError, "#{key} must be true or false" unless [true, false].include?(values.fetch(key))
      end

      if values.fetch(:parent_replace_writes) && !values.fetch(:all_writers_recursive_triggers)
        raise ArgumentError,
          "parent_replace_writes requires all_writers_recursive_triggers: true"
      end
      if values.fetch(:source_replace_writes) && !values.fetch(:all_writers_recursive_triggers)
        raise ArgumentError,
          "source_replace_writes requires all_writers_recursive_triggers: true"
      end

      %i[max_wal_bytes max_database_bytes].each do |key|
        value = values.fetch(key)
        raise ArgumentError, "#{key} must be positive or nil" unless value.nil? || (value.is_a?(Integer) && value.positive?)
      end
    end
  end
end
