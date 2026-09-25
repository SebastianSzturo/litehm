# frozen_string_literal: true

require "digest"

module LiteHM
  class SchemaReader
    SCHEMA_TYPES = %w[table index trigger view].freeze

    def initialize(connection)
      @connection = connection
    end

    def read(table)
      table = table.to_s
      table_row = schema_rows.find { |row| row.fetch("type") == "table" && row.fetch("name") == table }
      raise InvalidPlan, "table #{table.inspect} does not exist" unless table_row

      manifest = {
        "table" => table,
        "table_sql" => table_row.fetch("sql"),
        "columns" => pragma("table_xinfo", table),
        "indexes" => indexes(table),
        "foreign_keys" => pragma("foreign_key_list", table),
        "objects" => owned_objects(table),
        "dependent_views" => dependent_views(table),
        "dependent_triggers" => dependent_triggers(table),
        "inbound_foreign_keys" => inbound_foreign_keys(table),
        "sqlite_version" => @connection.first_value("SELECT sqlite_version()"),
        "compile_options" => @connection.execute("PRAGMA compile_options").map do |row|
          row.is_a?(Hash) ? row.fetch("compile_options") : row.fetch(0)
        end.sort
      }
      manifest["hash"] = digest(manifest)
      manifest.freeze
    end

    def supporting_schema(table)
      table = table.to_s
      tables = schema_rows.select do |row|
        row.fetch("type") == "table" && row.fetch("name") != table
      end
      table_names = tables.map { |row| row.fetch("name") }
      indexes = schema_rows.select do |row|
        row.fetch("type") == "index" && table_names.include?(row.fetch("tbl_name"))
      end
      views = schema_rows.select { |row| row.fetch("type") == "view" }
      supporting_names = table_names + views.map { |row| row.fetch("name") }
      triggers = schema_rows.select do |row|
        row.fetch("type") == "trigger" && supporting_names.include?(row.fetch("tbl_name"))
      end
      (tables + indexes + views + triggers).map(&:dup)
    end

    def self.digest(manifest)
      Digest::SHA256.hexdigest(CanonicalJSON.dump(manifest.reject { |key, _| key.to_s == "hash" }))
    end

    private

    def digest(manifest)
      self.class.digest(manifest)
    end

    def schema_rows
      @schema_rows ||= begin
        previous = @connection.database.results_as_hash
        @connection.database.results_as_hash = true
        rows = @connection.execute(<<~SQL)
          SELECT type, name, tbl_name, sql
          FROM sqlite_schema
          WHERE type IN ('table', 'index', 'trigger', 'view')
            AND name NOT GLOB 'sqlite_*'
            AND name NOT GLOB 'litehm_*'
            AND (name NOT GLOB '__litehm_*' OR type = 'index')
            AND sql IS NOT NULL
          ORDER BY type, name
        SQL
        rows.map { |row| row.slice("type", "name", "tbl_name", "sql") }
      ensure
        @connection.database.results_as_hash = previous
      end
    end

    def pragma(name, argument)
      previous = @connection.database.results_as_hash
      @connection.database.results_as_hash = true
      @connection.execute("PRAGMA #{name}(#{SQL.literal(argument)})").map do |row|
        row.reject { |key, _| key.is_a?(Integer) }
      end
    ensure
      @connection.database.results_as_hash = previous
    end

    def indexes(table)
      pragma("index_list", table).map do |index|
        physical_name = index.fetch("name")
        logical_name = logical_index_names(table).fetch(physical_name, physical_name)
        schema = schema_rows.find { |row| row.fetch("type") == "index" && row.fetch("name") == physical_name }
        sql = schema && schema.fetch("sql")
        index.merge(
          "name" => logical_name,
          "physical_name" => physical_name,
          "sql" => (SQL.rewrite_index(sql, logical_name) if sql),
          "columns" => pragma("index_xinfo", physical_name)
        )
      end.sort_by { |index| index.fetch("name") }
    end

    def owned_objects(table)
      schema_rows.select do |row|
        row.fetch("tbl_name") == table && !%w[table index].include?(row.fetch("type"))
      end
    end

    def logical_index_names(table)
      return {} unless @connection.first_value(<<~SQL)
        SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'litehm_index_names'
      SQL

      @connection.execute(<<~SQL, [table]).to_h { |logical, physical| [physical, logical] }
        SELECT logical_name, physical_name FROM litehm_index_names
        WHERE table_name = ? AND active = 1
      SQL
    end

    def inbound_foreign_keys(table)
      schema_rows.filter_map do |row|
        next unless row.fetch("type") == "table"
        next if row.fetch("name") == table

        references = pragma("foreign_key_list", row.fetch("name")).select { |fk| fk.fetch("table").tr("A-Z", "a-z") == table.tr("A-Z", "a-z") }
        next if references.empty?

        { "table" => row.fetch("name"), "references" => references }
      end
    end

    def dependent_views(table)
      dependent_objects(table, "view")
    end

    def dependent_triggers(table)
      dependent_objects(table, "trigger").reject { |row| row.fetch("tbl_name") == table }
    end

    def dependent_objects(table, type)
      identifier = Regexp.escape(table)
      pattern = /(?<![\w])(?:main\s*\.\s*)?(?:"#{identifier}"|`#{identifier}`|\[#{identifier}\]|#{identifier})(?![\w])/i
      schema_rows.select do |row|
        row.fetch("type") == type && row.fetch("sql").match?(pattern)
      end
    end
  end
end
