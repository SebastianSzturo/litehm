# frozen_string_literal: true

require_relative "../test_helper"
require "active_record"
require "stringio"

class IndexMappingTest < Minitest::Test
  def test_subsequent_plan_removes_prior_logical_index_name
    with_database do |path|
      first = LiteHM.change_table(:messages, id: "index-first", connection: path) do |table|
        table.add_index :body, name: :messages_body_lookup
      end
      assert first.cut_over?

      second_plan = LiteHM.plan(:messages, id: "index-second", connection: path) do |table|
        table.remove_index name: :messages_body_lookup
      end
      refute_includes second_plan.target_manifest.fetch("indexes").map { |index| index.fetch("name") },
        "messages_body_lookup"
      assert LiteHM.run(second_plan).cut_over?
      database = SQLite3::Database.new(path)
      assert_equal 0, database.get_first_value(<<~SQL)
        SELECT active FROM litehm_index_names
        WHERE table_name = 'messages' AND logical_name = 'messages_body_lookup'
      SQL
      database.close
    end
  end

  def test_active_record_remove_index_by_column_resolves_physical_name
    with_database do |path|
      LiteHM.change_table(:messages, id: "index-column-remove", connection: path) do |table|
        table.add_index :body, name: :messages_body_lookup
      end
      model = Class.new(ActiveRecord::Base)
      LiteHM.const_set(:IndexColumnConnection, model)
      model.abstract_class = true
      model.establish_connection(adapter: "sqlite3", database: path)
      connection = model.connection_pool.checkout
      LiteHM::ActiveRecordIntegration.install!

      connection.remove_index(:messages, :body)
      refute connection.index_exists?(:messages, :body, name: :messages_body_lookup)
      assert_nil connection.select_value(<<~SQL)
        SELECT 1 FROM litehm_index_names
        WHERE table_name = 'messages' AND logical_name = 'messages_body_lookup'
      SQL
    ensure
      model&.connection_pool&.disconnect!
      LiteHM.send(:remove_const, :IndexColumnConnection) if LiteHM.const_defined?(:IndexColumnConnection, false)
    end
  end

  def test_active_record_indexes_and_schema_dump_expose_logical_names
    with_database do |path|
      LiteHM.change_table(:messages, id: "index-ar", connection: path) do |table|
        table.add_index :body, name: :messages_body_lookup
      end
      model = Class.new(ActiveRecord::Base)
      LiteHM.const_set(:IndexMappingConnection, model)
      model.abstract_class = true
      model.establish_connection(adapter: "sqlite3", database: path)
      connection = model.connection_pool.checkout
      LiteHM::ActiveRecordIntegration.install!

      assert connection.index_exists?(:messages, :body, name: :messages_body_lookup)
      names = connection.indexes(:messages).map(&:name)
      assert_includes names, "messages_body_lookup"
      refute names.any? { |name| name.start_with?("__litehm_index_") }

      output = StringIO.new
      ActiveRecord::SchemaDumper.dump(model.connection_pool, output)
      assert_includes output.string, 'name: "messages_body_lookup"'
      refute_includes output.string, "__litehm_index_"
    ensure
      model&.connection_pool&.disconnect!
      LiteHM.send(:remove_const, :IndexMappingConnection) if LiteHM.const_defined?(:IndexMappingConnection, false)
    end
  end
end
