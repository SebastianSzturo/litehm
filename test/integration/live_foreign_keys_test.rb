# frozen_string_literal: true

require_relative "../test_helper"

class LiveForeignKeysTest < Minitest::Test
  Crash = Class.new(Exception)

  def teardown
    LiteHM::Testing.reset!
  end

  def test_generated_parent_keys_are_rejected_before_shadow_cascades_can_diverge
    %w[STORED VIRTUAL].each do |storage|
      [false, true].each do |source_fk|
        with_database do |path|
          database = SQLite3::Database.new(path)
          database.execute_batch(<<~SQL)
            PRAGMA foreign_keys=ON;
            CREATE TABLE parents(id INTEGER PRIMARY KEY, base INTEGER,
              code INTEGER GENERATED ALWAYS AS (base * 10) #{storage} UNIQUE);
            CREATE TABLE children(id INTEGER PRIMARY KEY, parent_code INTEGER
              #{'REFERENCES parents(code) ON UPDATE CASCADE' if source_fk});
            CREATE INDEX children_parent_code ON children(parent_code);
            INSERT INTO parents(id,base) VALUES (1,1);
            INSERT INTO children VALUES (1,10);
          SQL
          plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) do |table|
            unless source_fk
              table.ddl <<~SQL
                DROP TABLE children;
                CREATE TABLE children(id INTEGER PRIMARY KEY, parent_code INTEGER REFERENCES parents(code) ON UPDATE CASCADE);
                CREATE INDEX children_parent_code ON children(parent_code);
              SQL
            end
          end
          error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan, through: :ready) }
          assert_match(/generated parent key/, error.message)
          assert_empty database.execute("SELECT name FROM sqlite_schema WHERE name GLOB '__litehm_*'")
          database.execute('UPDATE parents SET base=2 WHERE id=1')
          assert_equal [[source_fk ? 20 : 10]], database.execute('SELECT parent_code FROM children')
          assert_empty database.execute('PRAGMA foreign_key_check')
        ensure
          database&.close
        end
      end
    end
  end

  def test_prepared_generated_parent_key_plan_cannot_resume_and_promote_a_cascade
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA foreign_keys=ON;
        CREATE TABLE parents(id INTEGER PRIMARY KEY, base INTEGER,
          code INTEGER GENERATED ALWAYS AS (base * 10) STORED UNIQUE);
        CREATE TABLE children(id INTEGER PRIMARY KEY, parent_code INTEGER);
        CREATE INDEX children_parent_code ON children(parent_code);
        INSERT INTO parents(id,base) VALUES (1,1);
        INSERT INTO children VALUES (1,10);
      SQL
      plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) do |table|
        table.ddl <<~SQL
          DROP TABLE children;
          CREATE TABLE children(id INTEGER PRIMARY KEY, parent_code INTEGER REFERENCES parents(code) ON UPDATE CASCADE);
          CREATE INDEX children_parent_code ON children(parent_code);
        SQL
      end
      connection = LiteHM::Connection.open(path)
      runner = LiteHM::Runner.new(connection, plan)
      # Recreate a prepared operation admitted by the previous implementation.
      build_protocol = runner.method(:foreign_key_protocol)
      runner.define_singleton_method(:foreign_key_protocol) do
        protocol = build_protocol.call
        protocol.define_singleton_method(:reject_generated_parent_keys!) { |_groups| }
        protocol
      end
      assert runner.run(through: :ready).ready?
      database.execute('UPDATE parents SET base=2 WHERE id=1')
      shadow = LiteHM::SQL.identifier(LiteHM::SQL.artifact('shadow', plan.id))
      assert_equal [[20]], database.execute("SELECT parent_code FROM #{shadow}")
      assert_equal [[10]], database.execute('SELECT parent_code FROM children')
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      refute LiteHM.status(plan.id, connection: path).cut_over?
      assert_equal [[10]], database.execute('SELECT parent_code FROM children')
      assert_equal 'aborted', LiteHM.abort(plan.id, connection: path).phase
    ensure
      connection&.close
      database&.close
    end
  end

  def test_parent_delete_and_update_actions_preserve_live_table_semantics
    %w[CASCADE].concat(["SET NULL", "SET DEFAULT", "RESTRICT", "NO ACTION"]).each do |action|
      %w[DELETE UPDATE].each do |event|
        with_family(action:) do |path, database|
          plan = migration(path)
          LiteHM.run(plan, through: :ready)
          statement = event == "DELETE" ? "DELETE FROM parents WHERE id = 1" : "UPDATE parents SET id = 3 WHERE id = 1"
          if ["RESTRICT", "NO ACTION"].include?(action)
            assert_raises(SQLite3::ConstraintException, "#{action} #{event}") { database.execute(statement) }
          else
            database.execute(statement)
          end
          expected = database.execute("SELECT * FROM children ORDER BY id")
          assert LiteHM.run(plan).cut_over?, "#{action} #{event}"
          assert_equal expected, database.execute("SELECT * FROM children ORDER BY id")
          assert_empty database.execute("PRAGMA foreign_key_check")
          assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
        end
      end
    end
  end

  def test_stale_shadow_cannot_restrict_parent_writes
    ["RESTRICT", "NO ACTION"].each do |action|
      with_family(action:) do |path, database|
        plan = migration(path)
        LiteHM.run(plan, through: :ready)
        database.execute("DELETE FROM children WHERE parent_id = 1")
        database.execute("DELETE FROM parents WHERE id = 1")
        assert LiteHM.run(plan).cut_over?
        assert_empty database.execute("SELECT * FROM children")
      end
    end
  end

  def test_new_target_fk_parent_change_invalidates_an_already_validated_row
    with_family(action: "CASCADE", source_fk: false) do |path, database|
      plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) do |table|
        table.add_foreign_key :parents, column: :parent_id
      end
      LiteHM.run(plan, through: :ready)
      fired = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_cutover_acquire && !fired

        fired = true
        database.execute("DELETE FROM parents WHERE id = 1")
      end
      assert_raises(LiteHM::ValidationFailed) { LiteHM.run(plan) }
      assert fired
      assert_equal [[1, 1, 'value']], database.execute("SELECT * FROM children")
      assert_equal "ready", LiteHM.status(plan.id, connection: path).phase
      assert_empty database.execute("PRAGMA foreign_key_list(children)")
    end
  end

  def test_large_parent_invalidation_is_checked_while_draining_the_ready_tail
    with_family(action: "CASCADE", source_fk: false) do |path, database|
      database.execute(<<~SQL)
        WITH RECURSIVE ids(id) AS (SELECT 2 UNION ALL SELECT id + 1 FROM ids WHERE id < 800)
        INSERT INTO children SELECT id, 1, 'value' FROM ids
      SQL
      plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) do |table|
        table.add_foreign_key :parents, column: :parent_id
      end
      fired = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :before_ready_acquire && !fired

        fired = true
        database.execute("DELETE FROM parents WHERE id = 1")
      end
      assert_raises(LiteHM::ValidationFailed) { LiteHM.run(plan) }
      assert fired
      refute LiteHM.status(plan.id, connection: path).cut_over?
      assert_empty database.execute("PRAGMA foreign_key_list(children)")
      assert_equal 800, database.get_first_value("SELECT COUNT(*) FROM children")
    end
  end

  def test_transformed_identity_is_reconciled_after_parent_update
    with_family(action: "CASCADE") do |path, database|
      plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) do |table|
        table.project :id, "id + 100"
      end
      LiteHM.run(plan, through: :ready)
      database.execute("UPDATE parents SET id = 3 WHERE id = 1")
      assert LiteHM.run(plan).cut_over?
      assert_equal [[101, 3, 'value']], database.execute("SELECT * FROM children")
      assert_empty database.execute("PRAGMA foreign_key_check")
    end
  end

  def test_released_archive_cannot_restrict_parent_writes_after_a_crash
    with_family(action: "RESTRICT") do |path, database|
      plan = migration(path)
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        raise Crash if point == :after_cutover_commit
      end
      assert_raises(Crash) { LiteHM.run(plan) }
      assert_equal "archive_released", LiteHM.status(plan.id, connection: path).phase
      database.execute("DELETE FROM children")
      database.execute("DELETE FROM parents WHERE id = 1")
      assert_empty database.execute("PRAGMA foreign_key_check")
      LiteHM::Testing.reset!
      assert LiteHM.run(plan).cut_over?
      assert_empty database.execute("SELECT name FROM sqlite_schema WHERE name GLOB '__litehm_guard_*'")
    end
  end

  def test_abort_and_cleanup_never_leave_triggers_pointing_at_dropped_tables
    with_family(action: "CASCADE") do |path, database|
      plan = migration(path)
      LiteHM.run(plan, through: :ready)
      checked = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :after_artifact_cleanup_batch && context[:table] == LiteHM::SQL.artifact("shadow", plan.id)

        checked = true
        database.execute("UPDATE parents SET id = id WHERE id = 1")
      end
      assert_equal "aborted", LiteHM.abort(plan.id, connection: path).phase
      assert checked
      assert_equal [[1, 1, 'value']], database.execute("SELECT * FROM children")
    end
    with_family(action: "CASCADE") do |path, database|
      plan = migration(path)
      checked = false
      LiteHM::Testing.fault_injector = lambda do |point, _context|
        next unless point == :after_cleanup_batch

        checked = true
        database.execute("UPDATE parents SET id = id WHERE id = 1")
      end
      assert LiteHM.run(plan).cut_over?
      assert checked
    end
  end

  def test_abort_removes_parent_guards_when_shadow_was_lost
    [false, true].each do |interrupted|
      with_family(action: "CASCADE") do |path, database|
        plan = migration(path)
        LiteHM.run(plan, through: :ready)
        if interrupted
          LiteHM::Testing.fault_injector = lambda do |point, _context|
            raise "interrupted abort" if point == :after_abort_started
          end
          assert_raises(RuntimeError) { LiteHM.abort(plan.id, connection: path) }
          LiteHM::Testing.reset!
        end
        database.execute("DROP TABLE #{LiteHM::SQL.identifier(LiteHM::SQL.artifact('shadow', plan.id))}")
        assert_equal "aborted", LiteHM.abort(plan.id, connection: path).phase
        assert_empty database.execute("SELECT name FROM sqlite_schema WHERE name GLOB '__litehm_guard_*'")
        database.execute("DELETE FROM parents WHERE id = 1")
        assert_empty database.execute("SELECT * FROM children")
        assert_empty database.execute("PRAGMA foreign_key_check")
      end
    end
  end

  def test_unindexed_source_or_target_fk_is_rejected_without_capture
    [true, false].each do |source_fk|
      with_family(action: "CASCADE", source_fk:) do |path, database|
        database.execute("DROP INDEX children_parent")
        plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) do |table|
          table.add_foreign_key :parents, column: :parent_id unless source_fk
        end
        error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
        assert_match(/indexed lookup/, error.message)
        assert_empty database.execute("SELECT name FROM sqlite_schema WHERE name GLOB '__litehm_*'")
        database.execute("DELETE FROM parents WHERE id = 1")
        assert_empty database.execute("PRAGMA foreign_key_check")
      end
    end
  end

  def test_parent_composite_affinity_scan_is_rejected_before_artifacts
    Dir.mktmpdir("litehm-composite-parent") do |directory|
      path = File.join(directory, "family.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE parents(a TEXT COLLATE NOCASE, b INTEGER, PRIMARY KEY(a, b)) WITHOUT ROWID;
        CREATE TABLE children(id INTEGER PRIMARY KEY, x TEXT COLLATE BINARY, y TEXT,
          FOREIGN KEY(x, y) REFERENCES parents(a, b) ON DELETE RESTRICT);
        INSERT INTO parents VALUES ('Alpha', 1);
        INSERT INTO children VALUES (1, 'alpha', '01');
      SQL
      plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) {}
      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan, through: :ready) }
      assert_match(/indexed lookup/, error.message)
      assert_empty database.execute("SELECT name FROM sqlite_schema WHERE name GLOB '__litehm_*'")
      database.execute("DELETE FROM children")
      database.execute("DELETE FROM parents")
      assert_empty database.execute("PRAGMA foreign_key_check")
    ensure
      database&.close
    end
  end

  def test_mixed_affinity_target_fk_is_rejected_before_artifacts
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        CREATE TABLE parents(code TEXT PRIMARY KEY NOT NULL);
        CREATE TABLE children(id INTEGER PRIMARY KEY, parent_code INTEGER);
        INSERT INTO parents VALUES ('01');
        INSERT INTO children VALUES (1, 1);
      SQL
      plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) do |table|
        table.add_foreign_key :parents, column: :parent_code, primary_key: :code
      end
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      refute LiteHM.status(plan.id, connection: path).cut_over?
    ensure
      database&.close
    end
  end

  def test_non_ascii_parent_names_do_not_share_a_pruning_trigger
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA foreign_keys = ON;
        CREATE TABLE "Ä"(id INTEGER PRIMARY KEY);
        CREATE TABLE "ä"(id INTEGER PRIMARY KEY);
        CREATE TABLE children(id INTEGER PRIMARY KEY, first_parent INTEGER REFERENCES "Ä",
          second_parent INTEGER REFERENCES "ä");
        CREATE INDEX children_first ON children(first_parent);
        CREATE INDEX children_second ON children(second_parent);
        INSERT INTO "Ä" VALUES (1);
        INSERT INTO "ä" VALUES (1);
        INSERT INTO children VALUES (1, 1, 1);
      SQL
      plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) {}
      LiteHM.run(plan, through: :ready)
      database.execute("DELETE FROM children")
      database.execute('DELETE FROM "Ä"')
      database.execute('DELETE FROM "ä"')
      assert LiteHM.run(plan).cut_over?
      assert_empty database.execute("PRAGMA foreign_key_check")
    ensure
      database&.close
    end
  end

  def test_parent_replace_obeys_recursive_trigger_contract
    with_family(action: "CASCADE") do |path, database|
      database.execute("PRAGMA recursive_triggers = ON")
      plan = LiteHM.plan(:children, connection: path,
        policy: { archive: :ephemeral, parent_replace_writes: true, all_writers_recursive_triggers: true }) {}
      LiteHM.run(plan, through: :ready)
      database.execute("INSERT OR REPLACE INTO parents VALUES (1)")
      assert LiteHM.run(plan).cut_over?
      assert_empty database.execute("SELECT * FROM children")
      assert_empty database.execute("PRAGMA foreign_key_check")
    end
  end

  def test_noop_parent_key_update_does_not_prune_shadow
    with_family(action: "CASCADE") do |path, database|
      plan = migration(path)
      LiteHM.run(plan, through: :ready)
      database.execute("UPDATE parents SET id = id WHERE id = 1")
      assert_equal 1, database.get_first_value("SELECT COUNT(*) FROM #{LiteHM::SQL.identifier(LiteHM::SQL.artifact('shadow', plan.id))}")
      assert_equal 0, database.get_first_value("SELECT COUNT(*) FROM #{LiteHM::SQL.identifier(LiteHM::SQL.artifact('dirty', plan.id))}")
    end
  end

  def test_parent_writes_after_sigkill_resume_from_durable_dirty_rows
    with_family(action: "SET NULL") do |path, database|
      plan = LiteHM.plan(:children, connection: path,
        policy: { archive: :ephemeral, lease_ttl_ms: 100 }) {}
      LiteHM.run(plan, through: :planned)
      database.close
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        LiteHM::Testing.fault_injector = lambda do |point, _context|
          next unless point == :after_copy_batch_commit

          writer.write("copied\n")
          writer.flush
          Process.kill("STOP", Process.pid)
        end
        LiteHM.run(plan)
        exit! 1
      end
      writer.close
      assert IO.select([reader], nil, nil, 10), "child failed to reach copy checkpoint"
      assert_equal "copied\n", reader.gets
      Process.kill("KILL", pid)
      Process.wait(pid)
      pid = nil
      database = SQLite3::Database.new(path)
      database.execute("PRAGMA foreign_keys = ON")
      database.execute("DELETE FROM parents WHERE id = 1")
      sleep 0.15
      assert LiteHM.run(plan).cut_over?
      assert_equal [[1, nil, 'value']], database.execute("SELECT * FROM children")
      assert_empty database.execute("PRAGMA foreign_key_check")
    ensure
      if pid
        Process.kill("KILL", pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
      reader&.close
      writer&.close unless writer&.closed?
      database&.close unless database&.closed?
    end
  end

  def test_parent_write_during_capture_repair_is_preserved
    with_family(action: "SET NULL") do |path, database|
      plan = migration(path)
      LiteHM.run(plan, through: :ready)
      database.execute("DROP TRIGGER #{LiteHM::SQL.identifier(LiteHM::SQL.artifact('capture_update', plan.id))}")
      changed = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        next unless point == :after_artifact_cleanup_batch && !changed &&
          context[:table] == LiteHM::SQL.artifact('shadow', plan.id)

        changed = true
        database.execute("DELETE FROM parents WHERE id = 1")
      end
      assert LiteHM.run(plan).cut_over?
      assert changed
      assert_equal [[1, nil, 'value']], database.execute("SELECT * FROM children")
      assert_empty database.execute("PRAGMA foreign_key_check")
    end
  end

  def test_stored_legacy_plan_keeps_its_original_freeze_protocol
    with_family(action: "CASCADE") do |path, database|
      current = migration(path)
      legacy = LiteHM::Plan.new(**current.to_h.merge(
        compiler: current.compiler.reject { |key, _| key == 'foreign_key_protocol' }))
      LiteHM.run(legacy, through: :ready)
      error = assert_raises(SQLite3::ConstraintException) { database.execute("DELETE FROM parents WHERE id = 1") }
      assert_match(/parent key is frozen/, error.message)
      assert_equal "aborted", LiteHM.abort(legacy.id, connection: path).phase
      database.execute("DELETE FROM parents WHERE id = 1")
    end
  end

  private

  def migration(path)
    LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) do |table|
      table.add_index :value
    end
  end

  def with_family(action:, source_fk: true)
    Dir.mktmpdir("litehm-live-fk") do |directory|
      path = File.join(directory, "family.sqlite3")
      database = SQLite3::Database.new(path)
      reference = source_fk ? "REFERENCES parents(id) ON DELETE #{action} ON UPDATE #{action}" : ""
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE parents(id INTEGER PRIMARY KEY);
        CREATE TABLE children(id INTEGER PRIMARY KEY, parent_id INTEGER DEFAULT 2 #{reference}, value TEXT);
        CREATE INDEX children_parent ON children(parent_id);
        INSERT INTO parents VALUES (1), (2);
        INSERT INTO children VALUES (1, 1, 'value');
      SQL
      yield path, database
    ensure
      database&.close
    end
  end
end
