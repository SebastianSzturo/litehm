# frozen_string_literal: true

module LiteHM
  # Let SQLite evaluate target affinities and generated columns without writing
  # a target row. A private BEFORE INSERT trigger measures NEW and then ignores
  # the insert, so even a large zeroblob is measured before record storage.
  class GeneratedRowSizer
    def initialize(plan)
      @database = SQLite3::Database.new(":memory:")
      @database.execute("PRAGMA foreign_keys = OFF")
      @database.execute(plan.target_manifest.fetch("table_sql"))
      columns = plan.target_manifest.fetch("columns")
      @projection_columns = plan.projection.keys
      primary = columns.select { |column| column.fetch("pk").positive? }
      if primary.one? && primary.first.fetch("type").casecmp?("INTEGER") &&
          plan.target_manifest.fetch("indexes").none? { |index| index["origin"] == "pk" }
        @rowid_column = primary.first.fetch("name")
      end
      table = SQL.identifier(plan.table)
      measurement_name = plan.table == "__litehm_measurement" ? "__litehm_measurement_2" : "__litehm_measurement"
      @measurement = SQL.identifier(measurement_name)
      @database.execute("CREATE TABLE #{@measurement}(bytes INTEGER NOT NULL)")
      @database.execute("INSERT INTO #{@measurement} VALUES (0)")
      bytes = columns.map do |column|
        "COALESCE(octet_length(NEW.#{SQL.identifier(column.fetch('name'))}), 0)"
      end.join(" + ")
      @database.execute(<<~SQL)
        CREATE TRIGGER __litehm_measure BEFORE INSERT ON #{table}
        BEGIN
          UPDATE #{@measurement} SET bytes = #{bytes};
          SELECT RAISE(IGNORE);
        END
      SQL
      names = @projection_columns.map { |name| SQL.identifier(name) }.join(", ")
      @insert_sql = "INSERT INTO #{table}(#{names}) VALUES (#{Array.new(@projection_columns.length, '?').join(', ')})"
    rescue Exception
      close
      raise
    end

    def size(values)
      if @rowid_column && values[@projection_columns.index(@rowid_column)].nil?
        raise UnsupportedObject, "generated target sizing requires an explicit non-NULL INTEGER PRIMARY KEY"
      end
      @database.execute(@insert_sql, values)
      @database.get_first_value("SELECT bytes FROM #{@measurement}")
    end

    def close
      @database&.close unless @database&.closed?
    end
  end
end
