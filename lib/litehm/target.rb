# frozen_string_literal: true

module LiteHM
  class Target
    attr_reader :table, :operations

    def initialize(table)
      @table = table.to_s
      @operations = []
    end

    def name
      SQL.identifier(table)
    end

    def ddl(sql)
      record(:ddl, sql.to_s)
    end

    def add_column(name, type, **options)
      record(:add_column, name.to_s, type.to_s, options)
    end

    def change_column(name, type, **options)
      record(:change_column, name.to_s, type.to_s, options)
    end

    def change_column_default(name, default_or_changes)
      record(:change_column_default, name.to_s, default_or_changes)
    end

    def change_column_null(name, null, default = nil)
      record(:change_column_null, name.to_s, !!null, default)
    end

    def rename_column(from, to)
      record(:rename_column, from.to_s, to.to_s)
    end

    def remove_column(name)
      record(:remove_column, name.to_s)
    end

    def add_index(columns, **options)
      record(:add_index, Array(columns).map(&:to_s), options)
    end

    def remove_index(columns = nil, **options)
      record(:remove_index, Array(columns).compact.map(&:to_s), options)
    end

    def rename_index(from, to)
      record(:rename_index, from.to_s, to.to_s)
    end

    def add_reference(name, **options)
      record(:add_reference, name.to_s, options)
    end

    alias add_belongs_to add_reference

    def remove_reference(name, **options)
      record(:remove_reference, name.to_s, options)
    end

    alias remove_belongs_to remove_reference

    def add_timestamps(**options)
      record(:add_timestamps, options)
    end

    def remove_timestamps(**options)
      record(:remove_timestamps, options)
    end

    def add_foreign_key(to_table, **options)
      record(:add_foreign_key, to_table.to_s, options)
    end

    def remove_foreign_key(to_table = nil, **options)
      record(:remove_foreign_key, to_table&.to_s, options)
    end

    def add_check_constraint(expression, **options)
      record(:add_check_constraint, expression.to_s, options)
    end

    def remove_check_constraint(**options)
      record(:remove_check_constraint, options)
    end

    def project(column, expression)
      record(:project, column.to_s, expression.to_s)
    end

    def intent
      operations.map { |operation| operation.dup.freeze }.freeze
    end

    private

    def record(operation, *arguments)
      @operations << [operation.to_s, *CanonicalJSON.normalize(arguments)]
      self
    end
  end
end
