# frozen_string_literal: true

require_relative "litehm/version"
require_relative "litehm/configuration"
require_relative "litehm/errors"
require_relative "litehm/canonical_json"
require_relative "litehm/value_codec"
require_relative "litehm/sql"
require_relative "litehm/policy"
require_relative "litehm/write_budget"
require_relative "litehm/generated_row_sizer"
require_relative "litehm/plan"
require_relative "litehm/receipt"
require_relative "litehm/status"
require_relative "litehm/connection"
require_relative "litehm/active_record_integration"
require_relative "litehm/schema_reader"
require_relative "litehm/target"
require_relative "litehm/scratch_compiler"
require_relative "litehm/store"
require_relative "litehm/planner"
require_relative "litehm/testing"
require_relative "litehm/telemetry"
require_relative "litehm/capabilities"
require_relative "litehm/foreign_key_protocol"
require_relative "litehm/runner"
require_relative "litehm/reverter"
require_relative "litehm/operation_job"
require_relative "litehm/recovery_job"
require_relative "litehm/engine"

require "digest"

module LiteHM
  module_function

  def configuration
    @configuration ||= Configuration.new
  end

  def configure
    yield configuration
  end

  def plan(table, id: nil, connection: nil, policy: {}, adapter: nil, &block)
    with_connection(connection || configured_connection) do |opened|
      if id && (stored = Store.new(opened).plan(id.to_s))
        target = Target.new(table)
        block&.call(target)
        intent_hash = Digest::SHA256.hexdigest(CanonicalJSON.dump(target.intent))
        candidate_policy = CanonicalJSON.normalize(Policy.new(**policy).to_h)
        conflict = intent_hash != stored.intent_hash || stored.table != table.to_s ||
          !Policy.compatible?(stored.policy, candidate_policy, overrides: CanonicalJSON.normalize(policy)) || (adapter && stored.adapter != adapter.to_s)
        if conflict
          raise PlanConflict.new("plan id #{id.inspect} is already bound to different intent",
            details: { plan_id: id.to_s, stored_intent_hash: stored.intent_hash,
              candidate_intent_hash: intent_hash, stored_table: stored.table,
              candidate_table: table.to_s })
        end
        return stored
      end
      Planner.new(connection: opened, table:, id:, policy:, adapter:, &block).call
    end
  end

  def run(plan, through: :cut_over, connection: nil, checkpoint: nil, command_state: nil)
    unless %i[planned ready cut_over].include?(through.to_sym)
      raise ArgumentError, "through must be :planned, :ready, or :cut_over"
    end

    with_connection(connection || plan.database_path, execution: true) do |opened|
      opened.busy_timeout_ms = plan.policy.fetch("busy_timeout_ms")
      stored = Store.new(opened).register(plan)
      return stored if through.to_sym == :planned

      Runner.new(opened, stored).run(through:, checkpoint:, command_state:)
    end
  end

  def status(plan_id, connection: nil)
    with_connection(connection || configured_connection) do |opened|
      Store.new(opened).status(plan_id.to_s, health: true)
    end
  end

  # Re-enqueues operations that still want work but have no live runner — for
  # example after a worker was SIGKILLed, OOM-killed, or its host rebooted, which
  # some Active Job backends (Solid Queue) record as a failed execution instead
  # of redelivering. Safe to run repeatedly: the writer lease serializes any
  # duplicate job, and each stall is re-enqueued at most once per stall window.
  def recover_stalled(connection: nil)
    resolved = connection || configured_connection
    candidates = with_connection(resolved, execution: true) do |opened|
      store = Store.new(opened)
      store.recovery_candidates.select { |status| store.claim_recovery(status.plan_id, status.recovery_enqueued_at) }
    end
    return [] if candidates.empty?

    database_path = connection_path(resolved)
    candidates.each do |status|
      Telemetry.emit("recovered", { version: 1, plan_id: status.plan_id, table: status.table,
        phase: status.phase, desired_state: status.desired_state,
        last_advanced_at: status.last_advanced_at })
      enqueue_operation(database_path, status.plan_id)
    end
  end

  # `start: :paused` registers the operation without starting it (async only):
  # nothing touches the table until an operator resumes it, so the heavy copy
  # runs when someone chooses, not when the deploy happens. Inline execution
  # always runs immediately.
  def change_table(table, execution: nil, start: :running, **options, &block)
    migration = plan(table, **options, &block)
    mode = (execution || configuration.execution_mode).to_sym
    case mode
    when :async
      submit(migration, connection: options[:connection], start:)
    when :inline
      run(migration, connection: options[:connection])
    else
      raise ArgumentError, "execution must be :async or :inline"
    end
  end

  def submit(plan, connection: nil, start: :running)
    stored, current = register_for_start(plan, connection || plan.database_path, start)
    return current if current.paused?

    enqueue_operation(stored.database_path, stored.id)
    status(stored.id, connection: stored.database_path)
  end

  def abort(plan_id, connection: nil, checkpoint: nil, command_state: nil)
    with_connection(connection || configured_connection, execution: true) do |opened|
      plan = Store.new(opened).plan(plan_id.to_s)
      raise InvalidPlan, "unknown LiteHM plan #{plan_id.inspect}" unless plan

      opened.busy_timeout_ms = plan.policy.fetch("busy_timeout_ms")
      Runner.new(opened, plan).abort(checkpoint:, command_state:)
    end
  end

  def cleanup(plan_id, connection: nil, checkpoint: nil, command_state: nil)
    with_connection(connection || configured_connection, execution: true) do |opened|
      plan = Store.new(opened).plan(plan_id.to_s)
      raise InvalidPlan, "unknown LiteHM plan #{plan_id.inspect}" unless plan

      opened.busy_timeout_ms = plan.policy.fetch("busy_timeout_ms")
      Runner.new(opened, plan).cleanup(checkpoint:, command_state:)
    end
  end

  def revert(receipt_or_id, connection: nil, id: nil, policy: {}, execution: nil, start: :running, &block)
    plan_id = receipt_or_id.is_a?(Receipt) ? receipt_or_id.plan_id : receipt_or_id.to_s
    with_connection(connection || configured_connection, execution: true) do |opened|
      store = Store.new(opened)
      forward_plan = store.plan(plan_id)
      receipt = receipt_or_id.is_a?(Receipt) ? receipt_or_id : store.receipt(plan_id)
      raise InvalidPlan, "unknown LiteHM receipt #{plan_id.inspect}" unless forward_plan && receipt
      raise InvalidPlan, "plan #{plan_id.inspect} has not cut over" unless receipt.cut_over?

      reverse_plan = Reverter.new(opened, forward_plan, receipt, id:, policy:, &block).plan
      opened.busy_timeout_ms = reverse_plan.policy.fetch("busy_timeout_ms")
      mode = (execution || configuration.execution_mode).to_sym
      case mode
      when :async
        stored, current = register_for_start(reverse_plan, opened.path, start)
        next current if current.paused?

        enqueue_operation(stored.database_path, stored.id)
        Store.new(opened).status(stored.id)
      when :inline
        Runner.new(opened, reverse_plan).run
      else
        raise ArgumentError, "execution must be :async or :inline"
      end
    end
  end

  def operations(connection: nil)
    with_connection(connection || configured_connection) { |opened| Store.new(opened).statuses(health: true) }
  end

  def pause(plan_id, connection: nil)
    command(plan_id, :paused, connection:, enqueue: false)
  end

  def resume(plan_id, connection: nil)
    command(plan_id, :running, connection:)
  end

  def request_cutover(plan_id, connection: nil)
    command(plan_id, :cutover_requested, connection:)
  end

  def request_abort(plan_id, connection: nil)
    command(plan_id, :abort_requested, connection:)
  end

  def request_cleanup(plan_id, connection: nil)
    command(plan_id, :cleanup_requested, connection:)
  end

  def retry_operation(plan_id, connection: nil)
    resolved = connection || configured_connection
    current = with_connection(resolved, execution: true) do |opened|
      store = Store.new(opened)
      plan = store.plan(plan_id.to_s)
      raise InvalidPlan, "unknown LiteHM plan #{plan_id.inspect}" unless plan

      opened.busy_timeout_ms = plan.policy.fetch('busy_timeout_ms')
      store.clear_error(plan_id.to_s)
      store.status(plan_id.to_s)
    end
    if current.desired_state == "paused"
      desired_state = case current.phase
      when "aborting" then :abort_requested
      when "archive_released" then :cleanup_requested
      else :running
      end
      command(plan_id, desired_state, connection: resolved)
    else
      enqueue_operation(connection_path(resolved), plan_id.to_s)
      current
    end
  end

  def command(plan_id, desired_state, connection: nil, enqueue: true)
    resolved = connection || configured_connection
    current = with_connection(resolved, execution: true) do |opened|
      store = Store.new(opened)
      status = store.status(plan_id.to_s)
      raise InvalidPlan, "unknown LiteHM plan #{plan_id.inspect}" if status.missing?

      plan = store.plan(plan_id.to_s)
      opened.busy_timeout_ms = plan.policy.fetch('busy_timeout_ms')
      allowed_phases = validate_command!(status, desired_state)
      store.command(plan_id.to_s, desired_state, phases: allowed_phases)
    end
    Telemetry.emit("command", { version: 1, plan_id: current.plan_id, table: current.table,
      phase: current.phase, desired_state: current.desired_state, pause_reason: current.pause_reason })
    enqueue_operation(connection_path(resolved), plan_id.to_s) if enqueue
    current
  end

  # Registers the plan; with `start: :paused` a newly registered plan is paused
  # before any job exists. Re-submitting an existing plan keeps its state.
  def register_for_start(plan, connection, start)
    unless %i[running paused].include?(start.to_sym)
      raise ArgumentError, "start must be :running or :paused"
    end

    with_connection(connection, execution: true) do |opened|
      opened.busy_timeout_ms = plan.policy.fetch("busy_timeout_ms")
      store = Store.new(opened)
      fresh = store.status(plan.id).missing?
      stored = store.register(plan)
      if fresh && start.to_sym == :paused
        store.command(stored.id, :paused, phases: %w[planned])
        current = store.status(stored.id)
        Telemetry.emit("state_changed", { version: 1, plan_id: current.plan_id, table: current.table,
          phase: current.phase, desired_state: current.desired_state, pause_reason: current.pause_reason })
      end
      [stored, store.status(stored.id)]
    end
  end

  def enqueue_operation(database_path, plan_id)
    job = OperationJob.perform_later(database_path, plan_id)
    unless job && job.successfully_enqueued?
      enqueue_error = job.respond_to?(:enqueue_error) && job.enqueue_error
      raise(enqueue_error || Error.new("Active Job did not enqueue LiteHM plan #{plan_id.inspect}"))
    end
    Telemetry.emit("enqueued", { version: 1, plan_id:, job_id: job.job_id, queue: job.queue_name })
    job
  rescue StandardError => error
    Telemetry.emit("enqueue_failed", { version: 1, plan_id:, error_class: error.class.name })
    record_failure(plan_id, database_path, error, pause: false)
    raise
  end

  def record_failure(plan_id, connection, error, pause: true)
    current = with_connection(connection, execution: true) do |opened|
      store = Store.new(opened)
      policy = store.plan(plan_id.to_s)&.policy
      opened.busy_timeout_ms = policy ? policy.fetch("busy_timeout_ms") : Policy::DEFAULTS.fetch(:busy_timeout_ms)
      store.fail(plan_id.to_s, error, pause:)
    end
    Telemetry.emit("state_changed", { version: 1, plan_id: current.plan_id, table: current.table,
      phase: current.phase, desired_state: current.desired_state, pause_reason: current.pause_reason,
      error_class: error.class.name })
    current
  end

  def with_open_connection(value, execution: false, &block)
    with_connection(value, execution:, &block)
  end

  def configured_connection
    resolver = configuration.connection
    resolver.respond_to?(:call) ? resolver.call : resolver
  end

  def connection_path(value)
    with_connection(value) { |opened| opened.path }
  end

  def validate_command!(status, desired_state)
    if desired_state.to_s == "running" && status.error
      raise InvalidPlan, "plan #{status.plan_id.inspect} has an error; use LiteHM.retry_operation"
    end
    allowed_phases = case desired_state.to_s
    when "running", "paused"
      %w[planned preparing ready]
    when "abort_requested"
      %w[planned preparing ready aborting]
    when "cutover_requested"
      %w[ready]
    when "cleanup_requested"
      %w[cut_over archive_released]
    else
      []
    end
    return allowed_phases if allowed_phases.include?(status.phase)

    raise AbortUnavailable,
      "#{desired_state} is unavailable while plan #{status.plan_id.inspect} is #{status.phase}"
  end

  def with_connection(value, execution: false)
    opened = Connection.open(value, dedicated: execution)
    yield opened
  ensure
    opened&.close
  end
  private_class_method :with_connection, :register_for_start
end
