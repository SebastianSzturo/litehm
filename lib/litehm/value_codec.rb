# frozen_string_literal: true

require "base64"

module LiteHM
  module ValueCodec
    module_function

    def encode_row(values)
      values.map { |value| encode(value) }
    end

    def decode_row(values)
      values.map { |value| decode(value) }
    end

    def encode(value)
      case value
      when nil
        { "type" => "null" }
      when Integer
        { "type" => "integer", "value" => value }
      when Float
        { "type" => "float", "value" => [value].pack("G").unpack1("H*") }
      when String
        if value.encoding == Encoding::BINARY
          { "type" => "blob", "value" => Base64.strict_encode64(value) }
        else
          { "type" => "text", "value" => value }
        end
      else
        raise TypeError, "unsupported SQLite value #{value.class}"
      end
    end

    def decode(encoded)
      case encoded.fetch("type")
      when "null" then nil
      when "integer" then encoded.fetch("value")
      when "float" then [encoded.fetch("value")].pack("H*").unpack1("G")
      when "blob" then Base64.strict_decode64(encoded.fetch("value"))
      when "text" then encoded.fetch("value")
      else raise TypeError, "unknown SQLite value encoding #{encoded.fetch("type").inspect}"
      end
    end
  end
end
