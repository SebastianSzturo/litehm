# frozen_string_literal: true

require_relative "../test_helper"
require "active_support/testing/event_reporter_assertions"

class TelemetryTest < Minitest::Test
  include ActiveSupport::Testing::EventReporterAssertions

  Subscriber = Struct.new(:callback) do
    def emit(event)
      callback.call(event)
    end
  end

  def teardown
    LiteHM::Testing.reset!
  end

  def test_rails_events_and_durable_summary_exclude_row_data
    with_database do |path|
      SQLite3::Database.open(path) { |db| db.execute("UPDATE messages SET body = 'customer-secret'") }
      plan = LiteHM.plan(:messages, connection: path, policy: { archive: :ephemeral }) { |t| t.add_index :body }
      events = []
      subscribe(->(event) { events << event }) do
        assert_event_reported("litehm.progress", payload: { plan_id: plan.id }) { LiteHM.run(plan) }
      end
      refute events.any? { |event| LiteHM::Telemetry::DEBUG_EVENTS.include?(event[:name]) }
      assert events.any? { |event| event[:name] == "litehm.state_changed" && event[:payload][:phase] == "done" }
      serialized = JSON.generate(events.map { |event| event[:payload] })
      refute_includes serialized, "customer-secret"
      refute_includes serialized, path
      refute_includes serialized, "CREATE INDEX"
      metrics = LiteHM.status(plan.id, connection: path).telemetry
      assert_equal 1, metrics["version"]
      assert_equal 2, metrics.dig("stages", "copy", "rows")
      assert_operator metrics.dig("stages", "copy", "rows_per_second"), :>, 0
      assert_operator metrics.dig("stages", "cleanup", "rows"), :>=, 2
      assert_equal 0, metrics["lock_retries"]
      assert_equal "sampled", metrics.dig("checkpoint", "status")
      assert_operator JSON.generate(metrics).bytesize, :<, 8_192
    end
  end

  def test_debug_subscribers_run_outside_the_sqlite_writer_transaction
    with_database do |path|
      # Enough rows for full 16-row batches, so the adaptive limit must move
      # regardless of how fast the host commits.
      SQLite3::Database.open(path) do |db|
        db.execute(<<~SQL)
          INSERT INTO messages(body, sent_at)
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200)
          SELECT 'row', i FROM n
        SQL
      end
      plan = LiteHM.plan(:messages, connection: path) { |t| t.add_index :body }
      probe = SQLite3::Database.new(path)
      probe.busy_timeout = 0
      errors = []
      seen = []
      callback = lambda do |event|
        next unless LiteHM::Telemetry::DEBUG_EVENTS.include?(event[:name])

        seen << event[:name]
        begin
          probe.execute("BEGIN IMMEDIATE")
          probe.execute("ROLLBACK")
        rescue SQLite3::Exception => error
          errors << error.class
        end
      end
      subscribe(callback) do
        with_debug_event_reporting { assert LiteHM.run(plan).cut_over? }
      end
      assert_includes seen, "litehm.batch"
      assert_includes seen, "litehm.checkpoint"
      assert_includes seen, "litehm.throttle_changed"
      assert_empty errors
    ensure
      probe&.close
    end
  end

  def test_a_broken_subscriber_cannot_fail_a_committed_migration
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) { |t| t.add_index :body }
      prior = Rails.event.send(:raise_on_error?)
      Rails.event.raise_on_error = true
      subscribe(->(_event) { raise "subscriber unavailable" }) do
        with_debug_event_reporting { assert LiteHM.run(plan).cut_over? }
      end
      SQLite3::Database.open(path) do |database|
        assert_equal 2, database.get_first_value("SELECT count(*) FROM messages")
        assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
      end
    ensure
      Rails.event.raise_on_error = prior
    end
  end

  def test_writer_and_cutover_contention_report_reasons_and_wait_time
    [:batch_selected, :before_cutover_acquire].each do |boundary|
      with_database do |path|
        plan = LiteHM.plan(:messages, connection: path,
          policy: { busy_timeout_ms: 5, cutover_acquire_ms: 5 }) { |t| t.add_index :body }
        blocker = SQLite3::Database.new(path)
        locked = false
        injected = false
        LiteHM::Testing.fault_injector = lambda do |point, context|
          next unless point == boundary && !injected
          next if boundary == :batch_selected && context[:kind] != :copy

          injected = locked = true
          blocker.execute("BEGIN IMMEDIATE")
        end
        reason = boundary == :batch_selected ? "writer_lock" : "cutover_lock"
        subscribe(lambda do |event|
          if event[:name] == "litehm.retry" && event[:payload][:reason] == reason && locked
            blocker.execute("ROLLBACK")
            locked = false
          end
        end) do
          assert_event_reported("litehm.retry", payload: { reason: }) { assert LiteHM.run(plan).cut_over? }
        end
        assert injected
        metrics = LiteHM.status(plan.id, connection: path).telemetry
        assert_equal 1, metrics["lock_retries"]
        assert_operator metrics["lock_wait_ms"], :>, 0
        assert_equal reason, metrics.dig("last_retry", "reason")
      ensure
        blocker&.execute("ROLLBACK") if locked
        blocker&.close
        LiteHM::Testing.reset!
      end
    end
  end

  def test_capped_dirty_sample_is_explicit_and_survives_operator_pause
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) { |t| t.add_index :body }
      inserted = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        if point == :batch_selected && context[:kind] == :copy && !inserted
          inserted = true
          SQLite3::Database.open(path) do |db|
            db.transaction { 300.times { db.execute("INSERT INTO messages(body) VALUES ('new')") } }
          end
        elsif point == :after_copy_batch_commit
          LiteHM.pause(plan.id, connection: path)
        end
      end
      assert_raises(LiteHM::Runner::ExecutionHalted) { LiteHM.run(plan) }
      status = LiteHM.status(plan.id, connection: path)
      assert status.paused?
      assert_equal "operator_pause", status.pause_reason
      assert_equal 251, status.progress["dirty_rows"]
      refute status.dirty_rows_exact?
      assert status.progress["dirty_rows_sampled_at"]
      # A pre-telemetry runner's stored count must also be treated as a bound.
      status.progress.delete("dirty_rows_exact")
      refute status.dirty_rows_exact?
    end
  end

  private

  def subscribe(callback)
    subscriber = Subscriber.new(callback)
    Rails.event.subscribe(subscriber) { |event| event[:name].start_with?("litehm.") }
    yield
  ensure
    Rails.event.unsubscribe(subscriber)
  end
end
