# frozen_string_literal: true

require "sqlite3"

module LiteHM
  class Connection
    attr_reader :database, :path, :adapter_name, :framework_connection, :busy_timeout_ms

    def self.open(value = nil, dedicated: false)
      value ||= default_active_record_connection

      if value.is_a?(String) || value.respond_to?(:to_path)
        path = File.expand_path(value.to_s)
        database = SQLite3::Database.new(path, flags: SQLite3::Constants::Open::READWRITE)
        new(database, path:, adapter_name: "sqlite3", owned: true)
      elsif active_record_connection?(value)
        ActiveRecordIntegration.install!
        database = value.raw_connection
        return dedicated_connection(database, adapter_name: "active_record", framework_connection: value) if dedicated
        new(database, path: database_path(database), adapter_name: "active_record", owned: false,
          framework_connection: value)
      elsif value.is_a?(SQLite3::Database)
        return dedicated_connection(value, adapter_name: "sqlite3") if dedicated
        new(value, path: database_path(value), adapter_name: "sqlite3", owned: false)
      else
        raise ArgumentError, "connection must be a database path, SQLite3::Database, or Active Record SQLite connection"
      end
    end

    def self.dedicated_connection(source, adapter_name:, framework_connection: nil)
      if source.transaction_active? || framework_connection&.transaction_open?
        raise InvalidPlan,
          "LiteHM requires its own transaction; call disable_ddl_transaction! in Rails migrations"
      end
      path = database_path(source)
      database = SQLite3::Database.new(path, flags: SQLite3::Constants::Open::READWRITE)
      # Preserve caller semantics/durability without touching its connection or
      # attempting to reconstruct an opaque custom busy-handler callback.
      %w[foreign_keys recursive_triggers ignore_check_constraints synchronous cache_size mmap_size journal_size_limit].each do |pragma|
        setting = source.get_first_value("PRAGMA #{pragma}")
        database.execute("PRAGMA #{pragma} = #{Integer(setting)}") unless setting.nil?
      end
      new(database, path:, adapter_name:, owned: true, framework_connection:)
    rescue Exception
      database&.close
      raise
    end

    def self.default_active_record_connection
      return unless defined?(ActiveRecord::Base)

      ActiveRecord::Base.connection
    rescue ActiveRecord::ConnectionNotEstablished
      nil
    end

    def self.active_record_connection?(value)
      value.respond_to?(:adapter_name) && value.adapter_name.to_s.match?(/sqlite/i) &&
        value.respond_to?(:raw_connection)
    end

    def self.database_path(database)
      rows = database.execute("PRAGMA database_list")
      row = rows.find { |entry| (entry.is_a?(Hash) ? entry["name"] : entry[1]) == "main" }
      path = row && (row.is_a?(Hash) ? row["file"] : row[2])
      raise ArgumentError, "LiteHM requires a file-backed main SQLite database" if path.nil? || path.empty?

      File.expand_path(path)
    end

    def initialize(database, path:, adapter_name:, owned:, framework_connection: nil)
      @database = database
      @path = path
      @adapter_name = adapter_name
      @owned = owned
      @framework_connection = framework_connection
      @original_results_as_hash = database.results_as_hash
      @busy_timeout_ms = database.get_first_value("PRAGMA busy_timeout")
      database.results_as_hash = false
    end

    def close
      database.results_as_hash = @original_results_as_hash unless database.closed?
      database.close if @owned
    end

    def busy_timeout_ms=(milliseconds)
      raise InvalidPlan, "execution requires a dedicated LiteHM connection" unless @owned

      @busy_timeout_ms = Integer(milliseconds)
      # Unlike PRAGMA busy_timeout, this releases Ruby's GVL between retries.
      # A waiting heartbeat must not prevent the worker from releasing its lock.
      database.busy_handler_timeout = @busy_timeout_ms
    end

    def prepare_writer_cache!
      raise InvalidPlan, "execution requires a dedicated LiteHM connection" unless @owned

      # A permitted 16 MiB row must fit alongside its source/target pages and
      # indexes. The raw SQLite default is only about 2 MiB, so prewarming a
      # large row otherwise evicts its own pages before the write begins.
      setting = first_value("PRAGMA cache_size").to_i
      bytes = setting.negative? ? -setting * 1024 : setting * first_value("PRAGMA page_size").to_i
      execute("PRAGMA cache_size = -65536") if bytes < 64 * 1024 * 1024
    end

    def clear_schema_cache!(table)
      framework_connection&.schema_cache&.clear_data_source_cache!(table.to_s)
    end

    def execute(sql, binds = [])
      database.execute(sql, binds)
    end

    def execute_batch(sql)
      database.execute_batch(sql)
    end

    def first_value(sql, binds = [])
      database.get_first_value(sql, binds)
    end

    def transaction(mode = :immediate)
      if database.transaction_active? || framework_connection&.transaction_open?
        raise InvalidPlan,
          "LiteHM requires its own transaction; call disable_ddl_transaction! in Rails migrations"
      end
      database.execute("BEGIN #{mode.to_s.upcase}")
      began = true
      result = yield
      database.execute("COMMIT")
      result
    rescue Exception
      database.execute("ROLLBACK") if began && database.transaction_active?
      raise
    end
  end
end
