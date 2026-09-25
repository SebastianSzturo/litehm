# frozen_string_literal: true

module LiteHM
  module ActiveRecordIntegration
    module SQLiteIndexNames
      def indexes(table_name)
        mappings = litehm_index_mappings(table_name)
        super.map do |definition|
          logical = mappings.key(definition.name)
          next definition unless logical

          definition.dup.tap { |copy| copy.instance_variable_set(:@name, logical) }
        end
      end

      def remove_index(table_name, column_name = nil, **options)
        mappings = litehm_index_mappings(table_name)
        logical = (options[:name] || index_name_for_remove(table_name, column_name, options)).to_s
        physical = mappings[logical]
        forwarded = options.merge(name: physical || logical)
        forwarded[:if_exists] = false if physical && forwarded[:if_exists]
        result = super(table_name, nil, **forwarded)
        if physical
          execute(<<~SQL)
            DELETE FROM litehm_index_names
            WHERE table_name = #{quote(table_name.to_s)} AND logical_name = #{quote(logical)}
          SQL
        end
        result
      end

      private

      def litehm_index_mappings(table_name)
        exists = select_value(<<~SQL)
          SELECT 1 FROM sqlite_schema
          WHERE type = 'table' AND name = 'litehm_index_names'
        SQL
        return {} unless exists

        select_rows(<<~SQL).to_h
          SELECT logical_name, physical_name FROM litehm_index_names
          WHERE table_name = #{quote(table_name.to_s)} AND active = 1
        SQL
      rescue ActiveRecord::StatementInvalid
        {}
      end
    end

    module_function

    def install!
      require "active_record/connection_adapters/sqlite3_adapter"
      adapter = ActiveRecord::ConnectionAdapters::SQLite3Adapter
      adapter.prepend(SQLiteIndexNames) unless adapter < SQLiteIndexNames
    end
  end
end
