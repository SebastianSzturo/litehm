# frozen_string_literal: true

require "digest"

module LiteHM
  class Planner
    def initialize(connection:, table:, id:, policy:, adapter: nil, &block)
      @connection = connection
      @table = table.to_s
      @id = id
      @policy = Policy.new(**policy)
      @policy_overrides = CanonicalJSON.normalize(policy)
      @adapter = adapter || connection.adapter_name
      @block = block
    end

    def call
      if @connection.framework_connection&.transaction_open?
        raise InvalidPlan,
          "LiteHM cannot run inside an Active Record transaction; call disable_ddl_transaction!"
      end
      reader = SchemaReader.new(@connection)
      source = reader.read(@table)
      @supporting_schema = reader.supporting_schema(@table)
      target = Target.new(@table)
      @block&.call(target)
      intent_operations = target.intent
      intent = {
        "operations" => intent_operations,
        "hash" => Digest::SHA256.hexdigest(CanonicalJSON.dump(intent_operations))
      }
      target_manifest, projection, compiler = compile(source, target)
      compiler = compiler.merge("policy_overrides" => @policy_overrides)
      id = @id&.to_s || derived_id(source.fetch("hash"), intent.fetch("hash"))

      Plan.new(
        id:, table: @table, database_path: @connection.path, adapter: @adapter,
        intent:, source_manifest: source, target_manifest:, projection:,
        compiler:, policy: CanonicalJSON.normalize(@policy.to_h)
      )
    end

    private

    def compile(source, target)
      result = ScratchCompiler.new(source:, target:, adapter_name: @adapter,
        supporting_schema: @supporting_schema).call
      [result.manifest, result.projection, result.fingerprint]
    end

    def derived_id(source_hash, intent_hash)
      suffix = Digest::SHA256.hexdigest([@table, source_hash, intent_hash].join("\0"))[0, 20]
      "#{@table}_#{suffix}"
    end
  end
end
