# frozen_string_literal: true

require "digest"

module LiteHM
  class Reverter
    def initialize(connection, forward_plan, receipt, id:, policy:, &block)
      @connection = connection
      @forward_plan = forward_plan
      @receipt = receipt
      @id = id || "revert_#{forward_plan.id}"
      # A revert rebuilds the same table, so it needs the same operational
      # contract (e.g. `archive: :ephemeral` for outbound foreign keys).
      # Explicit overrides still win.
      @policy = Policy.new(**inherited_policy(forward_plan).merge(policy))
      @block = block
    end

    def plan
      current = SchemaReader.new(@connection).read(@forward_plan.table)
      expected_schema = schema_signature(@forward_plan.target_manifest)
      actual_schema = schema_signature(current)
      unless @receipt.target_hash == @forward_plan.target_hash &&
          actual_schema == expected_schema
        raise SchemaDrift.new(
          "cannot revert #{@forward_plan.id.inspect}: the current schema is not its target schema",
          details: { plan_id: @forward_plan.id, expected_hash: @forward_plan.target_hash,
            receipt_hash: @receipt.target_hash, actual_hash: current.fetch("hash"),
            expected_schema_hash: Digest::SHA256.hexdigest(CanonicalJSON.dump(expected_schema)),
            actual_schema_hash: Digest::SHA256.hexdigest(CanonicalJSON.dump(actual_schema)) }
        )
      end
      explicit_target = Target.new(@forward_plan.table)
      @block&.call(explicit_target)
      unsupported = explicit_target.operations.reject { |operation| operation.first == "project" }
      unless unsupported.empty?
        raise InvalidPlan, "revert accepts only table.project overrides; its target is the stored source manifest"
      end

      explicit = explicit_target.operations.to_h { |(_, column, expression)| [column, expression] }
      projection = reverse_projection(current, explicit)
      operations = [["revert", @forward_plan.id], *explicit_target.intent]
      intent = {
        "operations" => operations,
        "hash" => Digest::SHA256.hexdigest(CanonicalJSON.dump(operations))
      }
      Plan.new(
        id: @id.to_s, table: @forward_plan.table, database_path: @connection.path,
        adapter: @forward_plan.adapter, intent:, source_manifest: current,
        target_manifest: @forward_plan.source_manifest, projection:,
        compiler: @forward_plan.compiler.merge("revert_of" => @forward_plan.id),
        policy: CanonicalJSON.normalize(@policy.to_h)
      )
    end

    private

    def inherited_policy(forward_plan)
      forward_plan.policy.each_with_object({}) do |(key, value), inherited|
        name = key.to_sym
        next unless Policy::DEFAULTS.key?(name)

        inherited[name] = Policy::DEFAULTS.fetch(name).is_a?(Symbol) ? value.to_sym : value
      end
    end

    def schema_signature(manifest)
      {
        "table_sql" => normalize_table_sql(manifest.fetch("table_sql")),
        "columns" => manifest.fetch("columns"),
        "indexes" => manifest.fetch("indexes").map do |index|
          {
            "name" => index.fetch("name"),
            "unique" => index.fetch("unique", 0),
            "origin" => index.fetch("origin"),
            "partial" => index.fetch("partial", 0),
            "columns" => index.fetch("columns"),
            "sql" => (SQL.rewrite_index(index.fetch("sql"), index.fetch("name"), "__litehm_table__") if index["sql"])
          }
        end.sort_by { |index| index.fetch("name") },
        "foreign_keys" => manifest.fetch("foreign_keys"),
        "objects" => manifest.fetch("objects"),
        "dependent_views" => manifest.fetch("dependent_views"),
        "dependent_triggers" => manifest.fetch("dependent_triggers", []),
        "inbound_foreign_keys" => manifest.fetch("inbound_foreign_keys")
      }
    end

    def normalize_table_sql(sql)
      pattern = /\ACREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"(?:[^"]|"")*"|`[^`]*`|\[[^\]]*\]|[^\s(]+)/i
      rewritten = sql.sub(pattern, "CREATE TABLE #{SQL.identifier('__litehm_table__')}")
      raise InvalidPlan, "cannot normalize target table SQL" if rewritten == sql

      rewritten
    end

    def reverse_projection(current, explicit)
      current_columns = current.fetch("columns").to_h { |column| [column.fetch("name"), column] }
      inverse = {}
      @forward_plan.projection.each do |current_name, expression|
        @forward_plan.source_manifest.fetch("columns").each do |old_column|
          old_name = old_column.fetch("name")
          inverse[old_name] = current_name if expression == SQL.identifier(old_name)
        end
      end

      @forward_plan.source_manifest.fetch("columns").filter_map do |old_column|
        next if old_column.fetch("hidden", 0).to_i != 0

        old_name = old_column.fetch("name")
        expression = explicit[old_name]
        current_name = inverse[old_name]
        expression ||= SQL.identifier(current_name) if current_name && current_columns.key?(current_name)
        unless expression
          raise ReverseProjectionRequired.new(
            "cannot reconstruct #{old_name.inspect}; provide table.project with a deterministic expression",
            details: { plan_id: @forward_plan.id, column: old_name }
          )
        end
        [old_name, expression]
      end.to_h
    end
  end
end
