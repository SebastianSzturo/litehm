# frozen_string_literal: true

module LiteHM
  class Store
    CONTROL_SQL = <<~SQL.freeze
      CREATE TABLE IF NOT EXISTS litehm_plans (
        plan_id TEXT PRIMARY KEY,
        table_name TEXT NOT NULL,
        intent_hash TEXT NOT NULL,
        source_hash TEXT NOT NULL,
        target_hash TEXT NOT NULL,
        phase TEXT NOT NULL,
        plan_json TEXT NOT NULL,
        error_json TEXT,
        progress_json TEXT NOT NULL DEFAULT '{}',
        archive_json TEXT NOT NULL DEFAULT '{}',
        receipt_json TEXT,
        retry_action TEXT NOT NULL DEFAULT 'resume',
        desired_state TEXT NOT NULL DEFAULT 'running',
        execution_revision INTEGER NOT NULL DEFAULT 0,
        last_advanced_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT;

      CREATE UNIQUE INDEX IF NOT EXISTS litehm_one_active_plan_per_table
        ON litehm_plans(table_name)
        WHERE phase IN ('planned', 'preparing', 'ready', 'aborting');

      CREATE TABLE IF NOT EXISTS litehm_index_names (
        table_name TEXT NOT NULL,
        logical_name TEXT NOT NULL,
        physical_name TEXT NOT NULL UNIQUE,
        plan_id TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
        PRIMARY KEY (table_name, logical_name)
      ) STRICT;

      CREATE TABLE IF NOT EXISTS litehm_leases (
        lease_name TEXT PRIMARY KEY,
        owner TEXT NOT NULL,
        epoch INTEGER NOT NULL,
        expires_at_ms INTEGER NOT NULL
      ) STRICT;
    SQL

    def initialize(connection)
      @connection = connection
    end

    def register(plan)
      unless File.realpath(plan.database_path) == File.realpath(@connection.path)
        raise PlanConflict, "plan database path does not match the execution connection"
      end
      @connection.transaction do
        @connection.execute_batch(CONTROL_SQL)
        upgrade_control_schema!
        existing = row(plan.id)
        if existing
          stored_plan(existing, plan)
        else
          now = Time.now.utc.iso8601(6)
          sql = <<~SQL
            INSERT INTO litehm_plans (
              plan_id, table_name, intent_hash, source_hash, target_hash, phase,
              plan_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 'planned', ?, ?, ?)
          SQL
          binds = [plan.id, plan.table, plan.intent_hash, plan.source_hash,
            plan.target_hash, CanonicalJSON.dump(plan.to_h), now, now]
          @connection.execute(sql, binds)
          plan
        end
      end
    rescue SQLite3::ConstraintException => error
      raise OperationConflict.new("another LiteHM plan already owns #{plan.table.inspect}",
        details: { table: plan.table, plan_id: plan.id }), cause: error
    end

    # `health: true` adds the stall assessment (writer lease + plan policy).
    # The runner's hot path never needs it, so it is opt-in.
    def status(plan_id, health: false)
      existing = row(plan_id)
      return Status.missing(plan_id) unless existing

      Status.new(
        plan_id: existing.fetch("plan_id"), table: existing.fetch("table_name"),
        phase: existing.fetch("phase"), source_hash: existing.fetch("source_hash"),
        target_hash: existing.fetch("target_hash"),
        error: parse_json(existing["error_json"]),
        progress: parse_json(existing.fetch("progress_json")),
        archive: parse_json(existing.fetch("archive_json")),
        retry_action: existing.fetch("retry_action"),
        desired_state: existing.fetch("desired_state", "running"),
        execution_revision: existing.fetch("execution_revision", 0).to_i,
        last_advanced_at: existing["last_advanced_at"],
        created_at: existing.fetch("created_at"), updated_at: existing.fetch("updated_at"),
        stalled: health ? stalled?(existing) : nil,
        recovery_enqueued_at: existing["recovery_enqueued_at"]
      )
    end

    def statuses(health: false)
      return [] unless control_table_exists?

      rows("SELECT plan_id FROM litehm_plans ORDER BY created_at DESC").map do |entry|
        status(entry.fetch("plan_id"), health:)
      end
    end

    # Stalled operations that have not already been re-enqueued since they last
    # advanced (or whose previous recovery is itself older than the stall window).
    def recovery_candidates(now: Time.now.utc)
      statuses(health: true).select do |status|
        next false unless status.stalled?

        previous = status.recovery_enqueued_at
        previous.nil? || previous < stall_reference(status.last_advanced_at, status.updated_at) ||
          Time.iso8601(previous) <= now - LiteHM.configuration.stalled_after
      end
    end

    # Compare-and-set so concurrent recoverers enqueue at most one job.
    def claim_recovery(plan_id, previous)
      upgrade_control_schema!
      @connection.execute(<<~SQL, [Time.now.utc.iso8601(6), plan_id, previous])
        UPDATE litehm_plans SET recovery_enqueued_at = ?
        WHERE plan_id = ? AND recovery_enqueued_at IS ?
      SQL
      @connection.database.changes == 1
    end

    def command(plan_id, desired_state, phases: nil, expected_state: nil)
      upgrade_control_schema! if control_table_exists?
      allowed = %w[running paused cutover_requested abort_requested cleanup_requested]
      state = desired_state.to_s
      raise ArgumentError, "unknown LiteHM desired state #{state.inspect}" unless allowed.include?(state)

      now = Time.now.utc.iso8601(6)
      phase_predicate = if phases
        " AND phase IN (#{Array.new(phases.length, '?').join(', ')})"
      else
        ""
      end
      state_predicate = expected_state ? " AND desired_state = ?" : ""
      binds = [state, now, plan_id, *Array(phases)]
      binds << expected_state.to_s if expected_state
      @connection.execute(<<~SQL, binds)
        UPDATE litehm_plans
        SET desired_state = ?, updated_at = ?, execution_revision = execution_revision + 1
        WHERE plan_id = ?#{phase_predicate}#{state_predicate}
      SQL
      if @connection.database.changes.zero?
        raise OperationConflict.new("LiteHM plan changed phase before the command was applied",
          details: { plan_id:, desired_state: state, allowed_phases: phases,
            expected_state: expected_state&.to_s })
      end

      status(plan_id)
    end

    def clear_error(plan_id)
      upgrade_control_schema! if control_table_exists?
      @connection.execute(
        "UPDATE litehm_plans SET error_json = NULL WHERE plan_id = ?", [plan_id]
      )
    end

    def touch(plan_id, progress: nil)
      now = Time.now.utc.iso8601(6)
      progress_assignment = progress ? ", progress_json = ?" : ""
      binds = [now, now]
      binds << CanonicalJSON.dump(progress) if progress
      binds << plan_id
      @connection.execute(<<~SQL, binds)
        UPDATE litehm_plans
        SET execution_revision = execution_revision + 1,
            last_advanced_at = ?, updated_at = ?#{progress_assignment}
        WHERE plan_id = ?
      SQL
      status(plan_id)
    end

    # Called inside an existing fenced transaction. No telemetry-only write
    # transaction, new control table, or unbounded history is needed.
    def save_telemetry(plan_id, snapshot)
      @connection.execute(<<~SQL, [CanonicalJSON.dump(snapshot), plan_id])
        UPDATE litehm_plans SET progress_json = json_set(progress_json, '$.telemetry', json(?))
        WHERE plan_id = ?
      SQL
    end

    def fail(plan_id, error, pause: true)
      details = {
        "class" => error.class.name,
        "message" => error.message,
        "details" => (error.respond_to?(:details) ? error.details : {})
      }
      now = Time.now.utc.iso8601(6)
      desired_assignment = if pause
        ", desired_state = CASE WHEN desired_state = 'running' THEN 'paused' ELSE desired_state END"
      else
        ""
      end
      @connection.execute(<<~SQL, [CanonicalJSON.dump(details), now, now, plan_id])
        UPDATE litehm_plans
        SET error_json = ?#{desired_assignment},
            execution_revision = execution_revision + 1,
            last_advanced_at = ?, updated_at = ?
        WHERE plan_id = ?
      SQL
      status(plan_id)
    end

    def plan(plan_id)
      existing = row(plan_id)
      existing && Plan.from_h(CanonicalJSON.load(existing.fetch("plan_json")))
    end

    def receipt(plan_id)
      existing = row(plan_id)
      return unless existing && existing["receipt_json"]

      attributes = CanonicalJSON.load(existing.fetch("receipt_json")).transform_keys(&:to_sym)
      Receipt.new(**attributes)
    end

    def transition(plan_id, phase:, progress: nil, archive: nil, receipt: nil,
      retry_action: "resume", error: nil, clear_error: false, desired_state: nil)
      now = Time.now.utc.iso8601(6)
      assignments = ["phase = ?", "retry_action = ?", "updated_at = ?",
        "last_advanced_at = ?", "execution_revision = execution_revision + 1"]
      binds = [phase.to_s, retry_action, now, now]
      {
        "progress_json" => progress,
        "archive_json" => archive,
        "receipt_json" => receipt&.to_h,
        "error_json" => error
      }.each do |column, value|
        next if value.nil?

        assignments << "#{column} = ?"
        binds << CanonicalJSON.dump(value)
      end
      if clear_error
        assignments << "error_json = NULL"
      end
      if desired_state
        assignments << "desired_state = ?"
        binds << desired_state.to_s
      end
      binds << plan_id
      @connection.execute(
        "UPDATE litehm_plans SET #{assignments.join(', ')} WHERE plan_id = ?", binds
      )
    end

    private

    def upgrade_control_schema!
      columns = @connection.execute("PRAGMA table_info(litehm_plans)").map { |row| row[1] }
      {
        "desired_state" => "TEXT NOT NULL DEFAULT 'running'",
        "execution_revision" => "INTEGER NOT NULL DEFAULT 0",
        "last_advanced_at" => "TEXT",
        "recovery_enqueued_at" => "TEXT"
      }.each do |name, declaration|
        next if columns.include?(name)

        @connection.execute("ALTER TABLE litehm_plans ADD COLUMN #{name} #{declaration}")
      end
    end

    def stalled?(existing, now: Time.now.utc)
      return false unless wants_execution?(existing)
      return false if writer_lease_live?(now)

      reference = stall_reference(existing["last_advanced_at"], existing.fetch("updated_at"))
      Time.iso8601(reference) <= now - LiteHM.configuration.stalled_after
    end

    # Phases where a worker still has work to do. Operations parked at a manual
    # cutover gate or a retained archive are waiting for an operator, not a worker.
    def wants_execution?(existing)
      desired = existing.fetch("desired_state", "running")
      return false if desired == "paused"

      case existing.fetch("phase")
      when "planned", "preparing", "aborting", "archive_released" then true
      when "ready"
        desired != "running" ||
          CanonicalJSON.load(existing.fetch("plan_json")).dig("policy", "cutover") != "manual"
      when "cut_over" then desired == "cleanup_requested"
      else false
      end
    end

    def writer_lease_live?(now)
      expires_at = @connection.first_value(
        "SELECT expires_at_ms FROM litehm_leases WHERE lease_name = 'writer'"
      )
      expires_at && expires_at.to_i > (now.to_f * 1_000).to_i
    rescue SQLite3::SQLException
      false
    end

    # Timestamps share one ISO 8601 UTC format, so they compare as strings.
    def stall_reference(last_advanced_at, updated_at)
      [last_advanced_at, updated_at].compact.max
    end

    def rows(sql, binds = [])
      previous = @connection.database.results_as_hash
      @connection.database.results_as_hash = true
      @connection.database.execute(sql, binds).map do |value|
        value.reject { |key, _| key.is_a?(Integer) }
      end
    ensure
      @connection.database.results_as_hash = previous if defined?(previous)
    end

    def stored_plan(existing, candidate)
      stored = Plan.from_h(CanonicalJSON.load(existing.fetch("plan_json")))
      if stored.intent_hash != candidate.intent_hash || stored.table != candidate.table ||
          stored.adapter.to_s != candidate.adapter.to_s ||
          !Policy.compatible?(stored.policy, candidate.policy, overrides: candidate.compiler.fetch("policy_overrides", {}))
        raise PlanConflict.new("plan id #{candidate.id.inspect} is already bound to different intent",
          details: { plan_id: candidate.id, stored_intent_hash: existing.fetch("intent_hash"),
            candidate_intent_hash: candidate.intent_hash })
      end

      stored
    end

    def row(plan_id)
      return nil unless control_table_exists?

      previous = @connection.database.results_as_hash
      @connection.database.results_as_hash = true
      value = @connection.database.get_first_row(
        "SELECT * FROM litehm_plans WHERE plan_id = ?", [plan_id]
      )
      value&.reject { |key, _| key.is_a?(Integer) }
    ensure
      @connection.database.results_as_hash = previous if defined?(previous)
    end

    def control_table_exists?
      @connection.first_value(<<~SQL) == 1
        SELECT 1 FROM sqlite_schema
        WHERE type = 'table' AND name = 'litehm_plans'
      SQL
    end

    def parse_json(value)
      value.nil? ? nil : CanonicalJSON.load(value)
    end
  end
end
