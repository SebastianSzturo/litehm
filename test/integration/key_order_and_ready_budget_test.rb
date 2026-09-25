# frozen_string_literal: true
require_relative '../test_helper'

class KeyOrderAndReadyBudgetTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_inbound_composite_keys_allow_permuted_order_but_preserve_column_collations
    [["PRIMARY KEY(b,a)", "a,b", "'alpha','Beta'"],
      ["UNIQUE(a,b)", "b,a", "'Beta','alpha'"]].each do |key, references, values|
      with_database do |path|
        db = SQLite3::Database.new(path)
        primary = key.start_with?('PRIMARY')
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys=ON;
          CREATE TABLE parents(#{'id INTEGER PRIMARY KEY,' unless primary}
            a TEXT COLLATE NOCASE, b TEXT COLLATE BINARY, extra TEXT, #{key}) #{'WITHOUT ROWID' if primary};
        SQL
        db.execute("CREATE TABLE children(id INTEGER PRIMARY KEY, x TEXT, y TEXT, FOREIGN KEY(x,y) REFERENCES parents(#{references}))")
        db.execute("INSERT INTO parents(a,b,extra) VALUES ('Alpha','Beta','value')")
        db.execute("INSERT INTO children VALUES (1,#{values})")
        assert LiteHM.change_table(:parents, connection: path) { |t| t.add_index :extra }.cut_over?
        db.execute("INSERT INTO children VALUES (2,#{values})")
        assert_empty db.execute('PRAGMA foreign_key_check')
        changed = LiteHM.plan(:parents, connection: path) do |t|
          t.ddl <<~SQL
            DROP TABLE parents;
            CREATE TABLE parents(#{'id INTEGER PRIMARY KEY,' unless primary}
              a TEXT COLLATE BINARY, b TEXT COLLATE NOCASE, extra TEXT, #{key}) #{'WITHOUT ROWID' if primary};
          SQL
        end
        error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(changed) }
        assert_match(/collation-compatible/, error.message)
        refute_nil error.details.fetch(:source_key)
      ensure
        db&.close
      end
    end
  end

  def test_ready_hold_uses_the_atomic_hold_budget_not_the_adaptive_target
    [false, true].each do |over_budget|
      with_database do |path|
        db = SQLite3::Database.new(path)
        plan = LiteHM.plan(:messages, connection: path,
          policy: { writer_lease_ms: 10, cutover_hold_ms: 1000, max_ready_batches: 1 }) {}
        connection = LiteHM::Connection.open(path)
        runner = LiteHM::Runner.new(connection, plan)
        clock = runner.method(:monotonic_time)
        offset = 0.0
        runner.define_singleton_method(:monotonic_time) { clock.call + offset }
        runner.define_singleton_method(:sleep) { |_duration| }
        checked = false
        LiteHM::Testing.fault_injector = lambda do |point, context|
          if point == :before_ready_acquire
            db.execute("UPDATE messages SET body='changed' WHERE id=1")
          elsif point == :before_final_validation && context[:target_identities].any?
            checked = true
            offset += over_budget ? 2.0 : 0.1
          end
        end
        if over_budget
          assert_raises(LiteHM::BusyBudgetExceeded) { runner.run(through: :ready) }
          refute_equal 'ready', LiteHM.status(plan.id, connection: path).phase
        else
          assert runner.run(through: :ready).ready?
        end
        assert checked
        assert_equal 'changed', db.get_first_value('SELECT body FROM messages WHERE id=1')
      ensure
        connection&.close
        db&.close
      end
    end
  end
end
