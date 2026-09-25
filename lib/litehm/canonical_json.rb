# frozen_string_literal: true

require "json"
require "time"

module LiteHM
  module CanonicalJSON
    module_function

    def dump(value)
      JSON.generate(normalize(value))
    end

    def load(value)
      JSON.parse(value)
    end

    def normalize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), normalized|
          normalized[key.to_s] = normalize(child)
        end.sort.to_h
      when Array
        value.map { |child| normalize(child) }
      when Symbol
        value.to_s
      when Time
        value.utc.iso8601(6)
      else
        value
      end
    end
  end
end
