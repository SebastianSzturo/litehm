# frozen_string_literal: true

module LiteHM
  class Plan
    ATTRIBUTES = %i[
      id table database_path adapter intent source_manifest target_manifest
      projection compiler policy
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(**attributes)
      missing = ATTRIBUTES - attributes.keys
      raise ArgumentError, "missing plan attributes: #{missing.join(', ')}" unless missing.empty?

      ATTRIBUTES.each do |attribute|
        value = attributes.fetch(attribute)
        instance_variable_set("@#{attribute}", deep_freeze(value))
      end
      freeze
    end

    def self.from_h(attributes)
      new(**attributes.transform_keys(&:to_sym))
    end

    def intent_hash
      intent.fetch("hash")
    end

    def source_hash
      source_manifest.fetch("hash")
    end

    def target_hash
      target_manifest.fetch("hash")
    end

    def to_h
      ATTRIBUTES.to_h { |attribute| [attribute, public_send(attribute)] }
    end

    private

    def deep_freeze(value)
      case value
      when Hash
        value.transform_values { |child| deep_freeze(child) }.freeze
      when Array
        value.map { |child| deep_freeze(child) }.freeze
      else
        value.freeze
      end
    end
  end
end
