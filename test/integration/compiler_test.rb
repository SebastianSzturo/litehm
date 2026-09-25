# frozen_string_literal: true

require_relative "../test_helper"

class CompilerTest < Minitest::Test
  def test_structured_changes_compile_in_disposable_database
    with_database do |path|
      before = schema_snapshot(path)
      plan = LiteHM.plan(:messages, connection: path) do |table|
        table.rename_column :body, :content
        table.change_column :content, :text, null: false
        table.remove_column :metadata
        table.add_column :delivered, :boolean, null: false, default: false
        table.add_index %i[delivered sent_at], name: :messages_delivery
      end

      assert_equal before, schema_snapshot(path)
      assert_equal %w[id content sent_at delivered], plan.target_manifest.fetch("columns").map { |column| column.fetch("name") }
      assert_equal %w[content delivered id sent_at], plan.projection.keys.sort
      assert_equal %Q{"body"}, plan.projection.fetch("content")
      assert_includes %w[FALSE 0], plan.projection.fetch("delivered")
      assert_includes plan.target_manifest.fetch("indexes").map { |index| index.fetch("name") }, "messages_delivery"
      assert_match(/STRICT\z/, plan.target_manifest.fetch("table_sql"))
    end
  end

  def test_raw_ddl_is_compiled_by_sqlite
    with_database do |path|
      plan = LiteHM.plan(:messages, connection: path, adapter: :raw) do |table|
        table.ddl "CREATE INDEX messages_body_prefix ON #{table.name} (substr(body, 1, 3)) WHERE body IS NOT NULL"
      end

      index = plan.target_manifest.fetch("indexes").find { |entry| entry.fetch("name") == "messages_body_prefix" }
      refute_nil index
      assert_match(/substr\(body, 1, 3\)/, index.fetch("sql"))
    end
  end

  def test_invalid_target_is_rejected_before_live_mutation
    with_database do |path|
      before = schema_snapshot(path)

      assert_raises(LiteHM::InvalidPlan) do
        LiteHM.plan(:messages, connection: path) do |table|
          table.add_column :required_value, :text, null: false
        end
      end
      assert_equal before, schema_snapshot(path)
    end
  end

  def test_narrowing_affinity_change_requires_explicit_projection
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("UPDATE messages SET body = '12abc' WHERE id = 1")
      database.close

      error = assert_raises(LiteHM::InvalidPlan) do
        LiteHM.plan(:messages, connection: path) { |table| table.change_column :body, :integer }
      end
      assert_match(/explicit table\.project/, error.message)

      plan = LiteHM.plan(:messages, connection: path) do |table|
        table.change_column :body, :integer
        table.project :body, "CASE WHEN body GLOB '[0-9]*' THEN CAST(body AS INTEGER) ELSE NULL END"
      end
      assert_match(/CASE WHEN/, plan.projection.fetch("body"))
    ensure
      database&.close
    end
  end

  def test_intent_hash_is_independent_of_hash_key_order
    with_database do |path|
      first = LiteHM.plan(:messages, connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      second = LiteHM.plan(:messages, connection: path) do |table|
        table.add_column :flag, :integer, default: 0, null: false
      end

      assert_equal first.intent_hash, second.intent_hash
      assert_equal first.id, second.id
    end
  end

  def test_nested_reference_options_are_deeply_symbolized
    with_database do |path|
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE people(id INTEGER PRIMARY KEY)")
      database.close

      plan = LiteHM.plan(:messages, id: "nested-reference", connection: path) do |table|
        table.add_reference :author, foreign_key: { to_table: :people }
      end
      assert_equal ["people"], plan.target_manifest.fetch("foreign_keys")
        .map { |foreign_key| foreign_key.fetch("table") }
    ensure
      database&.close
    end
  end

  def test_raw_ddl_cannot_be_mixed_with_structured_operations
    with_database do |path|
      error = assert_raises(LiteHM::InvalidPlan) do
        LiteHM.plan(:messages, id: "mixed-target", connection: path) do |table|
          table.ddl "ALTER TABLE #{table.name} ADD COLUMN raw_value TEXT"
          table.add_index :raw_value
        end
      end
      assert_match(/cannot be combined/, error.message)
    end
  end

  def test_structured_rebuild_preserves_without_rowid
    Dir.mktmpdir("litehm-without-rowid") do |directory|
      path = File.join(directory, "pairs.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE pairs(a TEXT NOT NULL, b TEXT NOT NULL, value TEXT,
          PRIMARY KEY(a, b)) WITHOUT ROWID;
        INSERT INTO pairs VALUES ('a', 'b', NULL);
      SQL
      database.close

      plan = LiteHM.plan(:pairs, id: "preserve-without-rowid", connection: path) do |table|
        table.change_column_null :value, false, "missing"
      end
      assert_match(/WITHOUT\s+ROWID\z/i, plan.target_manifest.fetch("table_sql"))
      assert LiteHM.run(plan).cut_over?
      database = SQLite3::Database.new(path)
      assert_match(/WITHOUT\s+ROWID\z/i, database.get_first_value(
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'pairs'"
      ))
      assert_equal "missing", database.get_first_value("SELECT value FROM pairs")
    ensure
      database&.close
    end
  end
end
