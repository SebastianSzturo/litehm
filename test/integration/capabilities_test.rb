# frozen_string_literal: true

require_relative "../test_helper"

class CapabilitiesTest < Minitest::Test
  def test_rollback_journal_is_rejected_before_capture
    Dir.mktmpdir("litehm-journal") do |directory|
      path = File.join(directory, "delete.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT)")
      database.close
      plan = LiteHM.plan(:items, connection: path) { |table| table.add_column :flag, :integer }

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_equal "delete", error.details.fetch(:journal_mode)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    ensure
      database&.close
    end
  end

  def test_nondeterministic_projection_is_rejected_before_capture
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) do |table|
        table.add_column :nonce, :integer
        table.project :nonce, "random()"
      end

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_equal "nonce", error.details.fetch(:column)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  def test_omitted_argument_time_function_is_rejected_before_capture
    [
      "datetime()", "date(/* omitted */)", "julianday()", "unixepoch()", "strftime('%s')",
      '"datetime"()', '"strftime"(\'%s\')'
    ].each_with_index do |expression, index|
      with_database do |path|
        plan = LiteHM.plan(:messages, id: "implicit-now-#{index}", connection: path) do |table|
          table.add_column :migrated_at, :text
          table.project :migrated_at, expression
        end

        error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
        assert_match(/not deterministic/, error.message)
        refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
      end
    end
  end

  def test_function_text_inside_a_literal_is_deterministic
    with_database do |path|
      receipt = LiteHM.change_table(:messages, id: "literal-function", connection: path) do |table|
        table.add_column :literal_value, :text
        table.project :literal_value, "'random()'"
      end
      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal ["random()", "random()"],
        database.execute("SELECT literal_value FROM messages ORDER BY id").flatten
    ensure
      database&.close
    end
  end

  def test_column_named_now_is_not_mistaken_for_current_time
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("ALTER TABLE messages ADD COLUMN now TEXT")
      database.execute("UPDATE messages SET now = 'fixed'")
      database.close

      receipt = LiteHM.change_table(:messages, id: "column-now", connection: path) do |table|
        table.add_column :copied_now, :text
        table.project :copied_now, "now"
      end
      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal %w[fixed fixed], database.execute("SELECT copied_now FROM messages").flatten
    ensure
      database&.close
    end
  end

  def test_self_mutating_trigger_dml_variants_require_recursive_trigger_contract
    variants = [
      "INSERT OR REPLACE INTO items(id, value) VALUES (NEW.id + 10, NEW.value)",
      "REPLACE INTO items(id, value) VALUES (NEW.id + 10, NEW.value)",
      "UPDATE OR IGNORE items SET value = NEW.value WHERE id = NEW.id + 1",
      "UPDATE OR ABORT \"items\" SET value = NEW.value WHERE id = NEW.id + 1",
      "UPDATE /* explanation */ OR IGNORE items SET value = NEW.value WHERE id = NEW.id + 1",
      "INSERT INTO /* target */ items(id, value) VALUES (NEW.id + 10, NEW.value)"
    ]
    variants.each_with_index do |statement, index|
      Dir.mktmpdir("litehm-self-trigger") do |directory|
        path = File.join(directory, "items.sqlite3")
        database = SQLite3::Database.new(path)
        database.execute_batch(<<~SQL)
          PRAGMA journal_mode = WAL;
          CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT);
          CREATE TRIGGER mutate_items AFTER INSERT ON items
          WHEN NEW.id < 10 BEGIN #{statement}; END;
        SQL
        database.close
        plan = LiteHM.plan(:items, id: "self-#{index}", connection: path) do |table|
          table.add_column :flag, :integer
        end

        error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
        assert_match(/recursive_triggers/, error.message)
      ensure
        database&.close
      end
    end
  end

  def test_projection_subquery_is_rejected_before_capture
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) do |table|
        table.add_column :message_count, :integer
        table.project :message_count, "(SELECT count(*) FROM messages)"
      end

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/outside the source row/, error.message)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  def test_cross_table_scalar_subquery_is_rejected_before_capture
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE settings(id INTEGER PRIMARY KEY, value TEXT)")
      database.execute("INSERT INTO settings VALUES (1, 'configured')")
      database.close
      plan = LiteHM.plan(:messages, id: "cross-table-projection", connection: path) do |table|
        table.add_column :setting, :text
        table.project :setting, "(SELECT value FROM settings WHERE id = messages.id)"
      end

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/outside the source row/, error.message)
    ensure
      database&.close
    end
  end

  def test_three_element_in_list_is_accepted_as_row_local
    with_database do |path|
      receipt = LiteHM.change_table(:messages, id: "row-local-in-list", connection: path) do |table|
        table.add_column :recognized_time, :integer, null: false, default: 0
        table.project :recognized_time, "sent_at IN (1, 2, 3)"
      end

      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal [1, 1], database.execute(
        "SELECT recognized_time FROM messages ORDER BY id"
      ).flatten
    ensure
      database&.close
    end
  end

  def test_projection_aggregate_is_rejected_before_capture
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path) do |table|
        table.add_column :body_count, :integer
        table.project :body_count, "count(body)"
      end

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/outside the source row/, error.message)
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end

  def test_projection_validation_does_not_replace_the_callers_authorizer
    with_database do |path|
      database = SQLite3::Database.new(path)
      calls = 0
      database.authorizer do |_action, _first, _second, _database, _trigger|
        calls += 1
        0
      end
      LiteHM.plan(:messages, id: "authorizer-preserved", connection: database) do |table|
        table.add_column :copy, :text
        table.project :copy, "body"
      end
      before = calls
      database.execute("SELECT body FROM messages")
      assert_operator calls, :>, before
    ensure
      database&.authorizer = nil unless database&.closed?
      database&.close unless database&.closed?
    end
  end

  def test_lossy_target_conflict_policy_is_rejected
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path, adapter: :raw) do |table|
        table.ddl "DROP TABLE #{table.name}; CREATE TABLE #{table.name} " \
          "(id INTEGER PRIMARY KEY, body TEXT UNIQUE ON CONFLICT REPLACE, sent_at INTEGER, metadata BLOB)"
      end

      error = assert_raises(LiteHM::UnsupportedObject) { LiteHM.run(plan) }
      assert_match(/REPLACE/, error.details.fetch(:policy))
      refute schema_snapshot(path).flatten.any? { |value| value.to_s.include?("__litehm_") }
    end
  end
end
