# frozen_string_literal: true

require "active_job"
require "active_job/continuation"

module LiteHM
  class OperationJob < ActiveJob::Base
    include ActiveJob::Continuable

    self.resume_errors_after_advancing = false
    queue_as { LiteHM.configuration.queue_name }

    retry_on SQLite3::BusyException, wait: 5.seconds, attempts: :unlimited
    retry_on LeaseConflict, wait: 5.seconds, attempts: :unlimited

    def perform(database_path, plan_id)
      step :execute, start: 0 do |step|
        execute_operation(database_path, plan_id, step)
      end
    end

    private

    def execute_operation(database_path, plan_id, step)
      plan = status = nil
      LiteHM.with_open_connection(database_path, execution: true) do |connection|
        store = Store.new(connection)
        plan = store.plan(plan_id)
        raise InvalidPlan, "unknown LiteHM plan #{plan_id.inspect}" unless plan

        connection.busy_timeout_ms = plan.policy.fetch("busy_timeout_ms")
        status = store.status(plan_id)
        if status.error && !status.paused? && !status.terminal?
          store.clear_error(plan_id)
          status = store.status(plan_id)
        end
      end
      return if status.paused? || status.terminal?

      checkpoint = ->(current, _kind) { step.set!(current.execution_revision) }
      Testing.inject(:before_operation_action, plan_id:, phase: status.phase,
        desired_state: status.desired_state)
      if status.phase == "aborting" || status.retry_action == "abort"
        LiteHM.abort(plan_id, connection: database_path, checkpoint:,
          command_state: status.desired_state)
      elsif status.phase == "archive_released"
        LiteHM.cleanup(plan_id, connection: database_path, checkpoint:,
          command_state: status.desired_state)
      else
        dispatch_desired_state(plan, status, database_path, plan_id, checkpoint)
      end
    rescue Runner::ExecutionHalted
      # The durable desired state changed at a committed safe point. A future
      # command submission starts a new job when work should continue.
      nil
    rescue LeaseConflict
      # A duplicate delivery or a crash can leave a live lease. Let Active Job
      # retry until the current owner finishes or the stale lease expires.
      raise
    rescue SQLite3::BusyException
      raise
    rescue Error => error
      preserve_command = command_pending?(database_path, plan_id, fallback: status)
      LiteHM.record_failure(plan_id, database_path, error, pause: !preserve_command)
      raise
    rescue StandardError => error
      preserve_command = command_pending?(database_path, plan_id, fallback: status)
      LiteHM.record_failure(plan_id, database_path, error, pause: !preserve_command)
      raise
    end

    def retry_job(options = {})
      error = options[:error]
      if error.is_a?(SQLite3::BusyException) || error.is_a?(LeaseConflict)
        wait = options[:wait]
        Telemetry.emit("retry", { version: 1, plan_id: arguments[1],
          reason: error.is_a?(LeaseConflict) ? "lease_conflict" : "job_busy",
          attempt: executions, error_class: error.class.name,
          wait_ms: wait.is_a?(Numeric) ? wait * 1_000 : nil })
      end
      result = super
      return result if result

      error = enqueue_error || ActiveJob::EnqueueError.new("LiteHM continuation was not enqueued")
      database_path, plan_id = arguments
      begin
        LiteHM.record_failure(plan_id, database_path, error, pause: false)
      rescue StandardError
        # Preserve the enqueue failure as the exception the backend sees. A
        # later delivery still reconstructs execution from the target ledger.
      end
      raise error
    end

    private

    def command_pending?(database_path, plan_id, fallback:)
      LiteHM.status(plan_id, connection: database_path).desired_state != "running"
    rescue StandardError
      fallback && fallback.desired_state != "running"
    end

    def dispatch_desired_state(plan, status, database_path, plan_id, checkpoint)
      case status.desired_state
      when "abort_requested"
        LiteHM.abort(plan_id, connection: database_path, checkpoint:,
          command_state: :abort_requested)
      when "cleanup_requested"
        LiteHM.cleanup(plan_id, connection: database_path, checkpoint:,
          command_state: :cleanup_requested)
      when "cutover_requested"
        LiteHM.run(plan, connection: database_path, checkpoint:,
          command_state: :cutover_requested)
      else
        through = plan.policy.fetch("cutover") == "manual" ? :ready : :cut_over
        LiteHM.run(plan, through:, connection: database_path, checkpoint:)
      end
    end
  end
end
