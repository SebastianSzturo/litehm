# frozen_string_literal: true
require_relative '../test_helper'

class EdgeCasesTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_uppercase_inbound_references_resolve_declared_column_names
    with_database do |path|
      db = SQLite3::Database.new(path)
      db.execute_batch('PRAGMA foreign_keys=ON; CREATE TABLE children(id INTEGER PRIMARY KEY, message_id REFERENCES MESSAGES(ID)); INSERT INTO children VALUES (1,1);')
      assert LiteHM.change_table(:messages, connection: path) { |t| t.add_index :body }.cut_over?
      assert_empty db.execute('PRAGMA foreign_key_check')
      plan = LiteHM.plan(:messages, connection: path) { |t| t.project :id, 'id + 10' }
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
    ensure
      db&.close
    end
  end

  def test_non_ascii_table_names_are_distinct_for_inbound_and_self_references
    [false, true].each do |outbound|
      with_database do |path|
        db = SQLite3::Database.new(path)
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys=ON;
          CREATE TABLE "Ä"(id INTEGER PRIMARY KEY);
          CREATE TABLE "ä"(id INTEGER PRIMARY KEY, parent_id INTEGER #{'REFERENCES "Ä"(id)' if outbound});
          CREATE INDEX lower_parent ON "ä"(parent_id);
          CREATE TABLE children(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES "Ä"(id));
          INSERT INTO "Ä" VALUES (1);
          INSERT INTO "ä" VALUES (1,1);
          INSERT INTO children VALUES (1,1);
        SQL
        assert LiteHM.change_table('ä', connection: path, policy: { archive: :ephemeral }) { |t|
          t.rename_column :id, :new_id
        }.cut_over?
        assert_equal [[1,1]], db.execute('SELECT * FROM "ä"')
        assert_empty db.execute('PRAGMA foreign_key_check')
      ensure
        db&.close
      end
    end
  end

  def test_capture_repair_keeps_a_durable_telemetry_sample_before_copy_resumes
    with_database do |path|
      db = SQLite3::Database.new(path)
      plan = LiteHM.plan(:messages, connection: path) { |t| t.add_index :body }
      LiteHM.run(plan, through: :ready)
      refute_empty LiteHM.status(plan.id, connection: path).telemetry
      db.execute("DROP TRIGGER #{LiteHM::SQL.identifier(LiteHM::SQL.artifact('capture_update', plan.id))}")
      checked = false
      LiteHM::Testing.fault_injector = lambda do |point, _|
        next unless point == :after_capture_repair
        checked = true
        sample = LiteHM.status(plan.id, connection: path).telemetry
        refute_empty sample
        assert_equal 'capture_repair', sample.fetch('stage')
        LiteHM.pause(plan.id, connection: path)
      end
      assert_raises(LiteHM::Runner::ExecutionHalted) { LiteHM.run(plan) }
      assert checked
      refute_empty LiteHM.status(plan.id, connection: path).telemetry
    ensure
      db&.close
    end
  end

  def test_tail_revalidation_does_not_exhaust_cutover_budget_on_pause_floors
    with_database do |path|
      db = SQLite3::Database.new(path)
      db.execute(<<~SQL)
        WITH RECURSIVE ids(id) AS (SELECT 3 UNION ALL SELECT id+1 FROM ids WHERE id<1000)
        INSERT INTO messages(id,body) SELECT id,'value' FROM ids
      SQL
      plan = LiteHM.plan(:messages, connection: path,
        policy: { min_batch_pause_ms: 1000, max_cutover_elapsed_ms: 5000 }) {}
      connection = LiteHM::Connection.open(path)
      runner = LiteHM::Runner.new(connection, plan)
      clock = runner.method(:monotonic_time)
      slept = 0.0
      runner.define_singleton_method(:sleep) { |duration| slept += duration }
      runner.define_singleton_method(:monotonic_time) { clock.call + slept }
      attempts = 0
      LiteHM::Testing.fault_injector = lambda do |point, _|
        next unless point == :before_cutover_acquire
        attempts += 1
        next if attempts > 2

        db.execute("UPDATE messages SET body='changed' WHERE id=1")
        raise LiteHM::Runner::TailTooLarge, 'retry the final tail'
      end
      assert runner.run.cut_over?
      assert_equal 3, attempts
      assert_equal 'changed', db.get_first_value('SELECT body FROM messages WHERE id=1')
    ensure
      connection&.close
      db&.close
    end
  end

  def test_validation_checkpoints_do_not_pay_the_write_batch_pause_floor
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path, policy: { min_batch_pause_ms: 1000 }) {}
      connection = LiteHM::Connection.open(path)
      runner = LiteHM::Runner.new(connection, plan)
      sleeps = []
      runner.define_singleton_method(:sleep) { |duration| sleeps << duration }
      phase_sleeps = {}
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :execution_checkpoint && %i[validate_source validate_target].include?(context[:kind])
        phase_sleeps[context[:kind]] = sleeps.last
      end
      runner.run(through: :ready)
      assert_equal %i[validate_source validate_target], phase_sleeps.keys.sort
      phase_sleeps.each_value { |delay| assert_operator delay, :<, 1.0 }
      assert sleeps.any? { |delay| delay >= 1.0 }, 'data writes must retain the configured floor'
    ensure
      connection&.close
    end
  end
end
