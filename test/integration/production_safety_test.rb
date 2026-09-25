# frozen_string_literal: true

require_relative "../test_helper"

class ProductionSafetyTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_rejected_nested_transaction_preserves_callers_uncommitted_work
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) {}
      database = SQLite3::Database.new(path)
      database.execute("BEGIN")
      database.execute("UPDATE messages SET body = 'pending' WHERE id = 1")
      assert_raises(LiteHM::InvalidPlan) { LiteHM.run(plan, connection: database) }
      assert database.transaction_active?, "LiteHM rolled back its caller's transaction"
      assert_equal "pending", database.get_first_value("SELECT body FROM messages WHERE id = 1")
      database.execute("ROLLBACK")
    ensure
      database&.close
    end
  end

  def test_registration_rejects_same_intent_for_another_table_or_policy
    with_database do |path|
      original = LiteHM.plan(:messages, id: "bound", connection: path) {}
      LiteHM.run(original, through: :planned)
      [{ table: "other" }, { adapter: "other" },
        { policy: original.policy.merge("archive" => "ephemeral") }].each do |change|
        candidate = LiteHM::Plan.new(**original.to_h.merge(change))
        assert_raises(LiteHM::PlanConflict) { LiteHM.run(candidate, through: :planned) }
      end
    end
  end

  def test_cleanup_before_cutover_does_not_destroy_correspondence
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) { |table| table.project :id, 'id + 100' }
      LiteHM.run(plan, through: :ready)
      database = SQLite3::Database.new(path)
      name = LiteHM::SQL.identifier(LiteHM::SQL.artifact('correspondence', plan.id))
      before = database.execute("SELECT * FROM #{name}")
      assert_raises(LiteHM::AbortUnavailable) { LiteHM.cleanup(plan.id, connection: path) }
      assert_equal before, database.execute("SELECT * FROM #{name}")
    ensure
      database&.close
    end
  end

  def test_chained_renames_preserve_original_values
    with_database do |path|
      LiteHM.change_table(:messages, connection: path) do |table|
        table.rename_column :sent_at, :temporary
        table.rename_column :temporary, :delivered_at
      end
      database = SQLite3::Database.new(path)
      assert_equal [[1], [2]], database.execute("SELECT delivered_at FROM messages ORDER BY id")
    ensure
      database&.close
    end
  end

  def test_noop_column_addition_preserves_values_and_rename_lineage
    [nil, "default"].each do |default|
      with_database do |path|
        database = SQLite3::Database.new(path)
        database.execute("ALTER TABLE messages ADD COLUMN value TEXT DEFAULT #{LiteHM::SQL.value(default)}")
        database.execute("UPDATE messages SET value = 'valuable data'")
        LiteHM.change_table(:messages, connection: path) do |table|
          table.rename_column :value, :temporary
          table.add_column :temporary, :text, if_not_exists: true, default: default
          table.rename_column :temporary, :content
        end
        assert_equal [["valuable data"], ["valuable data"]],
          database.execute("SELECT content FROM messages ORDER BY id")
      ensure
        database&.close
      end
    end
  end

  def test_removed_and_readded_column_uses_new_default
    with_database do |path|
      LiteHM.change_table(:messages, connection: path) do |table|
        table.remove_column :sent_at
        table.add_column :sent_at, :integer, default: 99
      end
      database = SQLite3::Database.new(path)
      assert_equal [[99], [99]], database.execute("SELECT sent_at FROM messages ORDER BY id")
    ensure
      database&.close
    end
  end

  def test_similarly_named_application_trigger_is_not_hidden
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        CREATE TABLE inbox(payload TEXT);
        CREATE TRIGGER litehmXimport AFTER INSERT ON inbox
        BEGIN INSERT INTO messages(body) VALUES (NEW.payload); END;
      SQL
      plan = LiteHM.plan(:messages, connection: path) { |table| table.rename_column :body, :content }
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
    ensure
      database&.close
    end
  end

  def test_case_insensitive_inbound_foreign_key_prevents_parent_key_rename
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE children(id INTEGER PRIMARY KEY, message_id REFERENCES MESSAGES(id))")
      plan = LiteHM.plan(:messages, connection: path) { |table| table.rename_column :id, :new_id }
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
    ensure
      database&.close
    end
  end

  def test_stale_owned_trigger_is_rejected_during_compilation
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        CREATE TABLE audit(value TEXT);
        CREATE TRIGGER audit_messages AFTER UPDATE ON messages
        BEGIN INSERT INTO audit VALUES (NEW.body); END;
      SQL
      assert_raises(LiteHM::InvalidPlan) do
        LiteHM.plan(:messages, connection: path) { |table| table.remove_column :body }
      end
    ensure
      database&.close
    end
  end

  def test_connection_state_and_dynamic_time_projections_are_rejected
    ["total_changes()", "datetime(body)", "datetime('n' || 'ow')"].each do |expression|
      with_database do |path|
        plan = LiteHM.plan(:messages, connection: path) do |table|
          table.add_column :computed, :text
          table.project :computed, expression
        end
        assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
        database = SQLite3::Database.new(path)
        assert_empty database.execute("SELECT name FROM sqlite_schema WHERE name GLOB '__litehm_*'")
      ensure
        database&.close
      end
    end
  end

  def test_fixed_time_literal_is_accepted
    with_database do |path|
      receipt = LiteHM.change_table(:messages, connection: path) do |table|
        table.add_column :computed, :text
        table.project :computed, "datetime('2026-01-01', '+1 day')"
      end
      assert receipt.cut_over?
    end
  end

  def test_mixed_parent_comparisons_refuse_scanning_without_changing_live_cascades
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("PRAGMA foreign_keys = ON")
      database.execute_batch(<<~SQL)
        CREATE TABLE parents(id INTEGER PRIMARY KEY, code TEXT UNIQUE);
        INSERT INTO parents VALUES (1, 'a');
        CREATE TABLE children(id INTEGER PRIMARY KEY, parent_id REFERENCES parents ON UPDATE CASCADE,
          parent_code TEXT REFERENCES parents(code) ON UPDATE CASCADE);
        INSERT INTO children VALUES (1, 1, 'a');
      SQL
      plan = LiteHM.plan(:children, connection: path, policy: { archive: :ephemeral }) {}
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan, through: :ready) }
      assert_empty database.execute("SELECT name FROM sqlite_schema WHERE name GLOB '__litehm_*'")
      database.execute("UPDATE parents SET id = 2")
      database.execute("UPDATE parents SET code = 'b'")
      assert_equal [[1, 2, 'b']], database.execute("SELECT * FROM children")
    ensure
      database&.close
    end
  end

  def test_unpatched_sqlite_version_is_rejected
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) {}
      connection = LiteHM::Connection.open(path)
      # Simulate an older system-linked SQLite using the real file-backed schema.
      connection.define_singleton_method(:first_value) do |sql, binds = []|
        sql == "SELECT sqlite_version()" ? "3.51.2" : super(sql, binds)
      end
      error = assert_raises(LiteHM::VersionUnsupported) do
        LiteHM::Capabilities.new(connection, plan).validate!
      end
      assert_match(/WAL-reset/, error.message)
    ensure
      connection&.close
    end
  end

  def test_structured_rebuild_cannot_silently_remove_unique_constraint
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT UNIQUE)")
      assert_raises(LiteHM::UnsupportedObject) do
        LiteHM.plan(:items, connection: path) { |table| table.change_column_null :value, false }
      end
      database.execute("INSERT INTO items VALUES (1, 'a')")
      assert_raises(SQLite3::ConstraintException) { database.execute("INSERT INTO items VALUES (2, 'a')") }
    ensure
      database&.close
    end
  end

  def test_structured_rebuild_cannot_turn_generated_column_into_stored_data
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute(<<~SQL)
        CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT,
          size INTEGER GENERATED ALWAYS AS (length(value)) STORED)
      SQL
      assert_raises(LiteHM::UnsupportedObject) do
        LiteHM.plan(:items, connection: path) { |table| table.change_column_null :value, false }
      end
    ensure
      database&.close
    end
  end

  def test_ephemeral_policy_releases_archive_without_foreign_keys
    with_database do |path|
      receipt = LiteHM.change_table(:messages, connection: path, policy: { archive: :ephemeral }) {}
      assert_nil receipt.archive_name
      assert_equal "done", LiteHM.status(receipt.plan_id, connection: path).phase
    end
  end

  def test_plan_cannot_be_submitted_to_a_different_database
    with_database do |original|
      with_database do |other|
        plan = LiteHM.plan(:messages, connection: original) {}
        before = schema_snapshot(other)
        assert_raises(LiteHM::PlanConflict) { LiteHM.submit(plan, connection: other) }
        assert_equal before, schema_snapshot(other)
      end
    end
  end

  def test_caller_busy_timeout_is_restored
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("PRAGMA busy_timeout = 321")
      plan = LiteHM.plan(:messages, connection: database) {}
      LiteHM.run(plan, connection: database)
      assert_equal 321, database.get_first_value("PRAGMA busy_timeout")
    ensure
      database&.close
    end
  end

  def test_missing_database_path_is_not_created_by_status
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'missing.sqlite3')
      assert_raises(SQLite3::CantOpenException) { LiteHM.status('unknown', connection: path) }
      refute File.exist?(path)
    end
  end

  def test_comments_cannot_hide_a_lossy_conflict_policy
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path, adapter: :raw) do |table|
        table.ddl <<~SQL
          DROP TABLE #{table.name};
          CREATE TABLE #{table.name}(id INTEGER PRIMARY KEY,
            body TEXT UNIQUE ON /* policy */ CONFLICT /* action */ REPLACE, sent_at INTEGER, metadata BLOB);
        SQL
      end
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
    end
  end

  def test_disabled_check_enforcement_cannot_admit_invalid_target_rows
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("PRAGMA ignore_check_constraints = ON")
      plan = LiteHM.plan(:messages, connection: path) do |table|
        table.add_check_constraint "length(body) > 100", name: "long_body"
      end
      assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan, connection: database) }
      assert_equal [[1, 'hello'], [2, 'world']], database.execute("SELECT id, body FROM messages ORDER BY id")
    ensure
      database&.close
    end
  end
end
