# frozen_string_literal: true
require_relative "../test_helper"
class RegressionsTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_trigger_reads_supporting_view_chain
    with_database do |path|
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE settings(value TEXT);
        INSERT INTO settings VALUES ('configured');
        CREATE VIEW settings_base AS SELECT value FROM settings;
        CREATE VIEW settings_view AS SELECT value FROM settings_base;
        CREATE TABLE audit(value TEXT);
        CREATE TRIGGER message_audit AFTER INSERT ON messages BEGIN
          INSERT INTO audit SELECT value FROM settings_view;
        END;
      SQL
      assert LiteHM.change_table(:messages, connection: path) { |t| t.add_index :body }.cut_over?
      db.execute("INSERT INTO messages(body) VALUES ('new')")
      assert_equal [['configured']], db.execute('SELECT * FROM audit')
    ensure
      db&.close
    end
  end

  def test_trigger_writes_through_supporting_views_and_trigger_chains
    [:add_index, :change_column_default].each do |operation|
      with_database do |path|
        db = SQLite3::Database.new(path)
        db.execute_batch(<<~SQL)
          CREATE TABLE audit(value TEXT);
          CREATE VIEW audit_view AS SELECT value FROM audit;
          CREATE TRIGGER audit_view_insert INSTEAD OF INSERT ON audit_view BEGIN
            INSERT INTO audit VALUES (NEW.value);
          END;
          CREATE TABLE inbox(value TEXT);
          CREATE VIEW inbox_view AS SELECT value FROM inbox;
          CREATE TRIGGER inbox_view_insert INSTEAD OF INSERT ON inbox_view BEGIN
            INSERT INTO inbox VALUES (NEW.value);
          END;
          CREATE TRIGGER inbox_insert AFTER INSERT ON inbox BEGIN
            INSERT INTO audit_view VALUES (NEW.value);
          END;
        SQL
        %w[INSERT UPDATE DELETE].each do |event|
          db.execute(<<~SQL)
            CREATE TRIGGER message_#{event.downcase} AFTER #{event} ON messages BEGIN
              INSERT INTO inbox_view VALUES ('#{event}');
            END;
          SQL
        end
        result = LiteHM.change_table(:messages, connection: path) do |t|
          operation == :add_index ? t.add_index(:body) : t.change_column_default(:sent_at, 5)
        end
        assert result.cut_over?
        assert_empty db.execute('SELECT * FROM audit'), 'compilation/copy must not execute application triggers'
        db.execute("INSERT INTO messages(id,body) VALUES (3,'new')")
        db.execute("UPDATE messages SET body='updated' WHERE id=3")
        db.execute('DELETE FROM messages WHERE id=3')
        assert_equal [['INSERT'], ['UPDATE'], ['DELETE']], db.execute('SELECT * FROM audit ORDER BY rowid')
        assert_equal 'ok', db.get_first_value('PRAGMA integrity_check')
      ensure
        db&.close
      end
    end
  end

  def test_trigger_writes_to_a_read_only_view_are_still_rejected
    with_database do |path|
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        CREATE TABLE audit(value TEXT);
        CREATE VIEW audit_view AS SELECT value FROM audit;
        CREATE TRIGGER message_audit AFTER INSERT ON messages BEGIN
          INSERT INTO audit_view VALUES (NEW.body);
        END;
      SQL
      error = assert_raises(LiteHM::InvalidPlan) do
        LiteHM.plan(:messages, connection: path) { |t| t.add_index :body }
      end
      assert_match(/cannot modify audit_view/, error.message)
    ensure
      db&.close
    end
  end

  def test_rebuilds_preserve_partial_and_expression_indexes
    %i[change_column change_column_default change_column_null].each do |operation|
      with_database do |path|
        db = SQLite3::Database.new(path)
        db.execute_batch(<<~SQL)
          CREATE INDEX message_partial ON messages(sent_at) WHERE body='hello';
          CREATE INDEX message_expression ON messages(lower(body));
        SQL
        result = LiteHM.change_table(:messages, connection: path) do |t|
          case operation
          when :change_column then t.change_column :metadata, :binary
          when :change_column_default then t.change_column_default :sent_at, 5
          when :change_column_null then t.change_column_null :sent_at, false, 0
          end
        end
        assert result.cut_over?, operation.to_s
        indexes = db.execute('PRAGMA index_list(messages)')
        assert_equal 3, indexes.length
        assert_equal 1, indexes.count { |r| r[4] == 1 }
        assert_equal 'ok', db.get_first_value('PRAGMA integrity_check')
        assert_equal [[1], [2]], db.execute('SELECT sent_at FROM messages ORDER BY id')
      ensure
        db&.close
      end
    end
  end

  def test_scalar_min_max_are_allowed_but_aggregates_still_refused
    with_database do |path|
      db = SQLite3::Database.new(path)
      assert LiteHM.change_table(:messages, connection: path) { |t| t.project :sent_at, 'max(10, min(sent_at, 20))' }.cut_over?
      assert_equal [[10], [10]], db.execute('SELECT sent_at FROM messages ORDER BY id')
      plan = LiteHM.plan(:messages, connection: path) { |t| t.project :sent_at, 'max(sent_at)' }
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
    ensure
      db&.close
    end
  end

  def test_removing_part_of_unique_index_cannot_narrow_uniqueness
    with_database do |path|
      db = SQLite3::Database.new(path)
      db.execute('CREATE UNIQUE INDEX message_pair ON messages(body, sent_at)')
      error = assert_raises(LiteHM::UnsupportedObject) do
        LiteHM.plan(:messages, connection: path) { |t| t.remove_column :sent_at }
      end
      assert_match(/index\/uniqueness/, error.message)
      assert_equal [[1], [2]], db.execute('SELECT sent_at FROM messages ORDER BY id')
    ensure
      db&.close
    end
  end

  def test_matching_composite_parent_keys_preserve_cascades
    %w[BINARY NOCASE].each do |collation|
      with_database do |path|
        db = SQLite3::Database.new(path)
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys=ON;
          CREATE TABLE parents(a TEXT COLLATE #{collation}, b TEXT, PRIMARY KEY(a,b)) WITHOUT ROWID;
          CREATE TABLE children(id INTEGER PRIMARY KEY, x TEXT COLLATE #{collation}, y TEXT,
            FOREIGN KEY(x,y) REFERENCES parents(a,b) ON UPDATE CASCADE ON DELETE CASCADE);
          CREATE INDEX child_parent ON children(x,y);
          INSERT INTO parents VALUES ('Alpha','one'),('Beta','two');
          INSERT INTO children VALUES (1,'#{collation == 'NOCASE' ? 'alpha' : 'Alpha'}','one'),(2,'Beta','two');
        SQL
        plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) { |t| t.add_index :y }
        LiteHM.run(plan, through: :ready)
        db.execute("UPDATE parents SET a='Gamma' WHERE a='Alpha'")
        db.execute("DELETE FROM parents WHERE a='Beta'")
        assert LiteHM.run(plan).cut_over?
        assert_equal [[1,'Gamma','one']], db.execute('SELECT * FROM children')
        assert_empty db.execute('PRAGMA foreign_key_check')
      ensure
        db&.close
      end
    end
  end

  def test_indexed_but_incompatible_parent_comparisons_remain_refused
    [["TEXT COLLATE NOCASE", "TEXT COLLATE BINARY", "'Alpha'", "'alpha'"],
      ["INTEGER", "TEXT", "1", "'01'"]].each do |parent_type, child_type, parent_value, child_value|
      with_database do |path|
        db = SQLite3::Database.new(path)
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys=ON;
          CREATE TABLE parents(code #{parent_type} PRIMARY KEY NOT NULL) WITHOUT ROWID;
          CREATE TABLE children(id INTEGER PRIMARY KEY, code #{child_type} REFERENCES parents(code) ON DELETE CASCADE);
          CREATE INDEX child_parent ON children(code);
          INSERT INTO parents VALUES (#{parent_value});
          INSERT INTO children VALUES (1,#{child_value});
        SQL
        plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) {}
        assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
        assert_empty db.execute("SELECT name FROM sqlite_schema WHERE name GLOB '__litehm_*'")
        db.execute('DELETE FROM children')
        db.execute('DELETE FROM parents')
        assert_empty db.execute('PRAGMA foreign_key_check')
      ensure
        db&.close
      end
    end
  end

  def test_explicit_index_removal_allows_removing_its_column
    with_database do |path|
      db = SQLite3::Database.new(path)
      db.execute('CREATE UNIQUE INDEX message_pair ON messages(body, sent_at)')
      assert LiteHM.change_table(:messages, connection: path) { |t|
        t.remove_index name: :message_pair
        t.remove_column :sent_at
      }.cut_over?
      db.execute("INSERT INTO messages(body) VALUES ('hello')")
      assert_equal 3, db.get_first_value('SELECT count(*) FROM messages')
    ensure
      db&.close
    end
  end

  def test_legacy_abort_releases_parent_freeze_before_shadow_drain
    with_database do |path|
      db = SQLite3::Database.new(path)
      db.execute_batch(<<~SQL)
        PRAGMA foreign_keys=ON;
        CREATE TABLE parents(id INTEGER PRIMARY KEY);
        CREATE TABLE children(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents ON DELETE CASCADE);
        CREATE INDEX child_parent ON children(parent_id);
        INSERT INTO parents VALUES (1);
        INSERT INTO children VALUES (1,1);
      SQL
      current = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) {}
      plan = LiteHM::Plan.new(**current.to_h.merge(compiler: current.compiler.reject { |k,_| k == 'foreign_key_protocol' }))
      LiteHM.run(plan, through: :ready)
      assert_raises(SQLite3::ConstraintException) { db.execute('DELETE FROM parents') }
      checked = false
      LiteHM::Testing.fault_injector = lambda do |point, _|
        next unless point == :after_abort_started
        checked = true
        db.execute('DELETE FROM parents')
      end
      assert_equal 'aborted', LiteHM.abort(plan.id, connection: path).phase
      assert checked
      assert_empty db.execute('SELECT * FROM children')
    ensure
      db&.close
    end
  end

  def test_legacy_registration_retains_stored_policy_across_default_changes
    with_database do |path|
      original = LiteHM.plan(:messages, id: 'legacy-defaults', connection: path) { |t| t.add_index :body }
      policy = original.policy.reject { |k,_| %w[max_batch_bytes max_row_bytes writer_duty_cycle min_batch_pause_ms].include?(k) }
        .merge('writer_lease_ms' => 75, 'cutover_hold_ms' => 500)
      legacy = LiteHM::Plan.new(**original.to_h.merge(policy:, compiler: original.compiler.reject { |k,_| k == 'policy_overrides' }))
      LiteHM.run(legacy, through: :planned)
      # Direct registration and the existing-id planning shortcut must agree.
      assert_equal policy, LiteHM.run(original, through: :planned).policy
      [{ archive: :ephemeral }, { writer_lease_ms: 10 }, { cutover_hold_ms: 50 },
        { max_row_bytes: 1024 }].each do |override|
        assert_raises(LiteHM::PlanConflict) do
          LiteHM.plan(:messages, id: legacy.id, connection: path, policy: override) { |t| t.add_index :body }
        end
        changed = LiteHM::Plan.new(**original.to_h.merge(
          policy: original.policy.merge(LiteHM::CanonicalJSON.normalize(override)),
          compiler: original.compiler.merge('policy_overrides' => LiteHM::CanonicalJSON.normalize(override))))
        assert_raises(LiteHM::PlanConflict) { LiteHM.run(changed, through: :planned) }
      end
      candidate = LiteHM.plan(:messages, id: legacy.id, connection: path) { |t| t.add_index :body }
      assert LiteHM.run(candidate).cut_over?
      assert_equal policy, candidate.policy
    end
  end
end
