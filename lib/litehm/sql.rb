# frozen_string_literal: true

require "digest"

module LiteHM
  module SQL
    module_function

    def identifier(value)
      %Q{"#{value.to_s.gsub('"', '""')}"}
    end

    def literal(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end

    def value(value)
      case value
      when nil then "NULL"
      when true then "1"
      when false then "0"
      when Integer, Float then value.to_s
      when String
        value.encoding == Encoding::BINARY ? "X'#{value.unpack1('H*')}'" : literal(value)
      else
        raise ArgumentError, "cannot render #{value.class} as a SQLite literal"
      end
    end

    def artifact(prefix, plan_id)
      digest = Digest::SHA256.hexdigest(plan_id.to_s)[0, 24]
      "__litehm_#{prefix}_#{digest}"
    end

    def rewrite_index(sql, index_name, table_name = nil)
      pattern = /\ACREATE\s+(UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"(?:[^"]|"")*"|`[^`]*`|\[[^\]]*\]|\S+)\s+ON\s+(?:"(?:[^"]|"")*"|`[^`]*`|\[[^\]]*\]|[^\s(]+)/i
      matched = false
      rewritten = sql.sub(pattern) do
        matched = true
        unique = Regexp.last_match(1)
        existing_table = Regexp.last_match(0).split(/\s+ON\s+/i, 2).last
        "CREATE #{unique}INDEX #{identifier(index_name)} ON #{table_name ? identifier(table_name) : existing_table}"
      end
      raise InvalidPlan, "cannot render target index SQL" unless matched

      rewritten
    end
  end
end
