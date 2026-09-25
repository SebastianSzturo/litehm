# frozen_string_literal: true

require "tmpdir"
require "strscan"

module LiteHM
  class ScratchCompiler
    SCHEMA_METHODS = %w[
      add_column change_column rename_column remove_column add_index remove_index
      add_foreign_key remove_foreign_key add_check_constraint remove_check_constraint
      change_column_default change_column_null rename_index add_reference remove_reference
      add_timestamps remove_timestamps
    ].freeze

    Result = Data.define(:manifest, :projection, :fingerprint)

    def initialize(source:, target:, adapter_name:, supporting_schema: [])
      @source = source
      @target = target
      @adapter_name = adapter_name
      @supporting_schema = supporting_schema
    end

    def call
      @column_lineage = @source.fetch("columns").to_h { |column| [column.fetch("name"), column.fetch("name")] }
      Dir.mktmpdir("litehm-compiler") do |directory|
        path = File.join(directory, "target.sqlite3")
        install_source(path)
        replay(path)
        preserve_table_options(path)
        connection = Connection.open(path)
        manifest = SchemaReader.new(connection).read(@source.fetch("table"))
        validate_dependent_views!(connection, manifest)
        validate_owned_triggers!(connection, manifest)
        validate_foreign_key_definitions!(connection, manifest)
        projection = build_projection(manifest)
        Result.new(manifest:, projection:, fingerprint: fingerprint(manifest))
      ensure
        connection&.close
      end
    rescue SQLite3::Exception, StandardError => error
      raise if error.is_a?(LiteHM::Error)

      raise InvalidPlan.new("target schema does not compile: #{error.message}",
        details: { exception: error.class.name }), cause: error
    end

    private

    def install_source(path)
      database = SQLite3::Database.new(path)
      database.execute("PRAGMA foreign_keys = OFF")
      @supporting_schema.select { |object| object.fetch("type") == "table" }
        .each { |object| database.execute(object.fetch("sql")) }
      @supporting_schema.select { |object| object.fetch("type") == "index" }
        .each { |object| database.execute(object.fetch("sql")) }
      database.execute(@source.fetch("table_sql"))
      @source.fetch("indexes").each do |index|
        database.execute(SQL.rewrite_index(index.fetch("sql"), index.fetch("name"))) if index["sql"]
      end
      @source.fetch("objects").select { |object| object.fetch("type") == "trigger" }
        .each { |object| database.execute(object.fetch("sql")) }
      (@supporting_schema.select { |object| object.fetch("type") == "view" } +
        @source.fetch("dependent_views", [])).uniq { |view| view.fetch("name") }
        .each { |view| database.execute(view.fetch("sql")) }
      # Compile the same reachable trigger graph as the live database, including
      # INSTEAD OF view triggers and table triggers that forward writes to views.
      @supporting_schema.select { |object| object.fetch("type") == "trigger" }
        .each { |object| database.execute(object.fetch("sql")) }
    ensure
      database&.close
    end

    def replay(path)
      schema_operations = @target.operations.reject { |operation| %w[ddl project].include?(operation.first) }
      raw_operations = @target.operations.select { |operation| operation.first == "ddl" }
      if schema_operations.any? && raw_operations.any?
        raise InvalidPlan,
          "raw ddl cannot be combined with structured schema operations; use one target definition style"
      end
      if schema_operations.any?
        replay_with_active_record(path, schema_operations)
      end

      return if raw_operations.empty?

      database = SQLite3::Database.new(path)
      raw_operations.each { |(_, sql)| database.execute_batch(sql) }
    ensure
      database&.close
    end

    def replay_with_active_record(path, operations)
      require "active_record"
      ActiveRecordIntegration.install!

      model = Class.new(ActiveRecord::Base)
      constant_name = "CompilerConnection#{object_id.abs}"
      LiteHM.const_set(constant_name, model)
      model.abstract_class = true
      model.establish_connection(adapter: "sqlite3", database: path)
      model.connection_pool.with_connection do |connection|
        operations.each { |operation| replay_operation(connection, operation) }
      end
    rescue LoadError => error
      raise UnsupportedObject.new(
        "Active Record is required for structured schema changes; use ddl for the raw sqlite3 adapter",
        details: { missing: "active_record" }
      ), cause: error
    ensure
      # Remove the pool, not just its connections: a disconnected pool stays
      # registered with the host application's connection handler (one leaked
      # entry per compiled plan) and points at a deleted scratch file.
      model&.remove_connection
      LiteHM.send(:remove_const, constant_name) if constant_name && LiteHM.const_defined?(constant_name, false)
    end

    def replay_operation(connection, operation)
      method, *arguments = operation
      raise UnsupportedObject, "unsupported target operation #{method.inspect}" unless SCHEMA_METHODS.include?(method)

      preserved = preservable_objects(connection)
      before = compiler_table_manifest(connection)
      original_arguments = arguments.dup
      if method == "rename_column"
        connection.execute(<<~SQL)
          ALTER TABLE #{SQL.identifier(@source.fetch("table"))}
          RENAME COLUMN #{SQL.identifier(arguments.fetch(0))} TO #{SQL.identifier(arguments.fetch(1))}
        SQL
      elsif method == "change_column_default"
        connection.public_send(method, @source.fetch("table"), arguments.fetch(0),
          deep_symbolize(arguments.fetch(1)))
      elsif method == "change_column_null"
        connection.public_send(method, @source.fetch("table"), *arguments)
      else
        options = arguments.last.is_a?(Hash) ? deep_symbolize(arguments.pop) : {}
        connection.public_send(method, @source.fetch("table"), *arguments, **options)
      end
      restore_objects(connection, preserved)
      after = compiler_table_manifest(connection)
      validate_preserved_features!(connection, before, after, method, original_arguments)
      # Track what the compiler actually changed. Conditional additions/removals
      # may be no-ops, and must not erase the existing column's source lineage.
      if method == "rename_column"
        @column_lineage[original_arguments[1]] = @column_lineage.delete(original_arguments[0])
      end
      removed = before.fetch("columns").map { |column| column.fetch("name") } -
        after.fetch("columns").map { |column| column.fetch("name") }
      removed.each { |name| @column_lineage.delete(name) }
    end

    def compiler_table_manifest(adapter)
      opened = Connection.open(adapter)
      SchemaReader.new(opened).read(@source.fetch("table"))
    ensure
      opened&.close
    end

    def validate_preserved_features!(connection, before, after, method, arguments)
      renamed = method == "rename_column" ? { arguments[0] => arguments[1] } : {}
      removed = case method
      when "remove_column" then [arguments[0]]
      when "remove_reference" then ["#{arguments[0]}_id", "#{arguments[0]}_type"]
      when "remove_timestamps" then %w[created_at updated_at]
      else []
      end
      before.fetch("columns").each do |column|
        next if column.fetch("hidden", 0).to_i.zero? || removed.include?(column.fetch("name"))

        name = renamed.fetch(column.fetch("name"), column.fetch("name"))
        target = after.fetch("columns").find { |entry| entry.fetch("name") == name }
        unless target && target.fetch("hidden", 0) == column.fetch("hidden")
          raise UnsupportedObject,
            "#{method} would lose generated column #{name.inspect}; use explicit raw ddl"
        end
      end
      identifiers = normalizable_columns(connection, after)
      before.fetch("indexes").each do |index|
        parts = index.fetch("columns").select { |part| part.fetch("key", 0).to_i == 1 }
        if parts.any? { |part| removed.include?(part["name"]) }
          # Rails rebuilds a composite index with its remaining keys. Silently
          # narrowing UNIQUE(a,b) to UNIQUE(a) changes the application's rules.
          retained = after.fetch("indexes").find { |entry| entry.fetch("name") == index.fetch("name") }
          next unless index.fetch("unique").to_i == 1 && retained
        end
        if method == "remove_index"
          options = arguments.last.is_a?(Hash) ? arguments.last : {}
          next if options["name"].to_s == index.fetch("name") ||
            (!options["name"] && Array(arguments[0]) == parts.map { |part| part["name"] })
        end
        # Native SQLite RENAME COLUMN already rewrites expression SQL atomically.
        next if method == "rename_column"

        expected = index_signature(index, renamed, identifiers:)
        next if after.fetch("indexes").any? { |candidate| index_signature(candidate, identifiers:) == expected }

        raise UnsupportedObject,
          "#{method} would lose or change index/uniqueness #{index.fetch('name').inspect}; use explicit raw ddl"
      end
    end

    def index_signature(index, renamed = {}, identifiers: [])
      parts = index.fetch("columns").select { |part| part.fetch("key", 0).to_i == 1 }
      complex = index.fetch("partial").to_i == 1 || parts.any? { |part| part["name"].nil? }
      [index.fetch("unique"), index.fetch("partial"),
        (normalized_index_sql(index.fetch("sql"), identifiers) if complex),
        parts.map do |part|
          [renamed.fetch(part["name"], part["name"]), part["coll"], part["desc"]]
        end]
    end

    def normalizable_columns(connection, manifest)
      manifest.fetch("columns").filter_map do |column|
        name = column.fetch("name")
        next unless name.match?(/\A[A-Za-z_][A-Za-z_0-9]*\z/)

        # Only equate bare and quoted names when SQLite resolves the bare token
        # as a column. Quoted "null", for example, must not become literal NULL.
        rows = connection.execute("EXPLAIN SELECT #{name} FROM #{SQL.identifier(manifest.fetch('table'))}")
        name.downcase if rows.any? { |row| %w[Column Rowid].include?(row["opcode"]) }
      rescue ActiveRecord::StatementInvalid
        nil
      end
    end

    def normalized_index_sql(sql, identifiers)
      scanner = StringScanner.new(SQL.rewrite_index(sql, "__index__", "__table__"))
      tokens = []
      until scanner.eos?
        next if scanner.scan(/\s+|--[^\n]*(?:\n|\z)|\/\*.*?\*\//m)

        if (token = scanner.scan(/'(?:[^']|'')*'/))
          tokens << [:string, token]
        elsif (token = scanner.scan(/"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]/))
          name = token[1...-1].gsub(token[0] * 2, token[0]).downcase
          tokens << (identifiers.include?(name) ? [:identifier, name] : [:quoted, token])
        elsif (token = scanner.scan(/[A-Za-z_][A-Za-z_0-9]*/))
          tokens << (identifiers.include?(token.downcase) ? [:identifier, token.downcase] : [:word, token.upcase])
        else
          tokens << [:operator, scanner.scan(/->>|->|!=|<>|==|<=|>=|\|\||<<|>>/) || scanner.getch]
        end
      end
      tokens
    end

    def deep_symbolize(value)
      return value unless value.is_a?(Hash)

      value.to_h { |key, child| [key.to_sym, deep_symbolize(child)] }
    end

    def preserve_table_options(path)
      structured = @target.operations.any? do |operation|
        !%w[ddl project].include?(operation.first)
      end
      return unless structured

      required = []
      source_sql = @source.fetch("table_sql")
      required << "WITHOUT ROWID" if source_sql.match?(/\bWITHOUT\s+ROWID\b/i)
      required << "STRICT" if source_sql.match?(/\bSTRICT\b/i)
      return if required.empty?

      database = SQLite3::Database.new(path)
      table = @source.fetch("table")
      current_sql = database.get_first_value(
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", [table]
      )
      current_sql = normalize_strict_types(database, table, current_sql) if required.include?("STRICT")
      missing = required.reject { |option| current_sql.match?(/\b#{option.gsub(' ', '\\s+')}\b/i) }
      stored_sql = database.get_first_value(
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", [table]
      )
      return if missing.empty? && current_sql == stored_sql

      objects = database.execute(<<~SQL, [table]).map { |row| row.fetch(0) }
        SELECT sql FROM sqlite_schema
        WHERE tbl_name = ? AND type IN ('index', 'trigger') AND sql IS NOT NULL
        ORDER BY type, name
      SQL
      separator = current_sql.match?(/\b(?:STRICT|WITHOUT\s+ROWID)\s*\z/i) ? ", " : " "
      rebuilt_sql = "#{current_sql}#{separator}#{missing.join(', ')}"
      database.execute("PRAGMA foreign_keys = OFF")
      database.transaction do
        database.execute("DROP TABLE #{SQL.identifier(table)}")
        database.execute(rebuilt_sql)
        objects.each { |sql| database.execute(sql) }
      end
    ensure
      database&.close
    end

    def normalize_strict_types(database, table, sql)
      allowed = %w[INT INTEGER REAL TEXT BLOB ANY]
      database.execute("PRAGMA table_xinfo(#{SQL.literal(table)})").each do |column|
        name = column.fetch(1)
        declared = column.fetch(2).to_s
        next if allowed.include?(declared.upcase)

        replacement = strict_storage_class(declared)
        quoted_name = Regexp.escape(SQL.identifier(name))
        sql = sql.sub(/(#{quoted_name}\s+)#{Regexp.escape(declared)}(?=\s|,|\))/i,
          "\\1#{replacement}")
      end
      sql
    end

    def strict_storage_class(declared)
      type = declared.upcase
      return "INTEGER" if type.include?("INT") || type.include?("BOOL")
      return "REAL" if type.match?(/REAL|FLOA|DOUB|DECIMAL|NUMERIC/)
      return "BLOB" if type.include?("BLOB") || type.include?("BINARY")

      "TEXT"
    end

    def validate_dependent_views!(connection, manifest)
      manifest.fetch("dependent_views", []).each do |view|
        connection.execute("SELECT * FROM #{SQL.identifier(view.fetch('name'))} LIMIT 0")
      rescue SQLite3::SQLException => error
        raise InvalidPlan.new("dependent view #{view.fetch('name').inspect} does not compile against the target",
          details: { view: view.fetch("name"), sqlite_error: error.message }), cause: error
      end
    end

    def preservable_objects(connection)
      quoted = connection.quote(@source.fetch("table"))
      connection.select_all(<<~SQL).to_a
        SELECT type, name, sql FROM sqlite_schema
        WHERE sql IS NOT NULL AND (
          (type = 'trigger' AND tbl_name = #{quoted}) OR type = 'view'
        )
        ORDER BY type, name
      SQL
    end

    def validate_owned_triggers!(connection, manifest)
      return unless manifest.fetch("objects").any? { |object| object.fetch("type") == "trigger" }

      table = SQL.identifier(manifest.fetch("table"))
      assignments = manifest.fetch("columns").filter_map do |column|
        next unless column.fetch("hidden", 0).to_i.zero?

        name = SQL.identifier(column.fetch("name"))
        "#{name} = #{name}"
      end
      # Preparing DML compiles trigger bodies without executing application code.
      connection.execute("EXPLAIN INSERT INTO #{table} DEFAULT VALUES")
      connection.execute("EXPLAIN UPDATE #{table} SET #{assignments.join(', ')}")
      connection.execute("EXPLAIN DELETE FROM #{table}")
    rescue SQLite3::SQLException => error
      raise InvalidPlan.new("target triggers do not compile: #{error.message}"), cause: error
    end

    def validate_foreign_key_definitions!(connection, manifest)
      return if manifest.fetch("foreign_keys").empty?

      connection.execute("PRAGMA foreign_keys = ON")
      connection.execute("EXPLAIN INSERT INTO #{SQL.identifier(manifest.fetch('table'))} DEFAULT VALUES")
    rescue SQLite3::SQLException => error
      raise InvalidPlan.new("target foreign keys do not compile: #{error.message}"), cause: error
    end

    def restore_objects(connection, objects)
      existing = connection.select_values("SELECT name FROM sqlite_schema")
      objects.each do |object|
        connection.execute(object.fetch("sql")) unless existing.include?(object.fetch("name"))
      end
    end

    def build_projection(target_manifest)
      source_columns = @source.fetch("columns").to_h { |column| [column.fetch("name"), column] }
      lineage = @column_lineage
      explicit = @target.operations.select { |operation| operation.first == "project" }
        .to_h { |(_, column, expression)| [column, expression] }
      null_backfills = @target.operations.select do |operation|
        operation.first == "change_column_null" && operation[2] == false && !operation[3].nil?
      end.to_h { |(_, column, _null, default)| [column, default] }

      target_manifest.fetch("columns").filter_map do |column|
        next if column.fetch("hidden", 0).to_i != 0

        name = column.fetch("name")
        explicit_projection = explicit.key?(name)
        expression = explicit[name]
        source_name = lineage[name]
        expression ||= SQL.identifier(source_name) if source_columns.key?(source_name)
        if expression && null_backfills.key?(name)
          expression = "COALESCE(#{expression}, #{SQL.value(null_backfills.fetch(name))})"
        end
        expression ||= default_expression(column)
        unless expression
          raise InvalidPlan, "new target column #{name.inspect} needs a default or table.project"
        end
        source_column = source_columns[source_name]
        if source_column && !explicit_projection &&
            affinity(source_column.fetch("type")) != affinity(column.fetch("type"))
          target_affinity = affinity(column.fetch("type"))
          unless target_affinity == "TEXT"
            raise InvalidPlan,
              "changing #{name.inspect} to #{target_affinity} affinity requires an explicit table.project"
          end
          expression = "CAST(#{expression} AS TEXT)"
        end
        [name, expression]
      end.to_h
    end

    def default_expression(column)
      value = column["dflt_value"]
      return value unless value.nil?
      return "NULL" unless column.fetch("notnull", 0).to_i == 1

      nil
    end

    def affinity(declared_type)
      type = declared_type.to_s.upcase
      return "INTEGER" if type.include?("INT")
      return "TEXT" if type.match?(/CHAR|CLOB|TEXT/)
      return "BLOB" if type.empty? || type.include?("BLOB")
      return "REAL" if type.match?(/REAL|FLOA|DOUB/)

      "NUMERIC"
    end

    def fingerprint(manifest)
      {
        "name" => @adapter_name,
        "litehm_version" => VERSION,
        "foreign_key_protocol" => ForeignKeyProtocol::VERSION,
        "sqlite_version" => manifest.fetch("sqlite_version"),
        "active_record_version" => (ActiveRecord.version.to_s if defined?(ActiveRecord))
      }.compact
    end
  end
end
