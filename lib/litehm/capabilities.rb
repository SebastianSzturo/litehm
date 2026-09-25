# frozen_string_literal: true

module LiteHM
  class Capabilities
    # Earlier SQLite releases include the WAL-reset corruption race. Require
    # the fixed mainline baseline, including for system-linked sqlite3 gems.
    MINIMUM_SQLITE = Gem::Version.new("3.51.3")
    NON_ROW_LOCAL_OPCODES = %w[
      AggStep AggFinal AggValue InitCoroutine Yield EndCoroutine
    ].freeze
    NONDETERMINISTIC_FUNCTION =
      /\b(?:random|randomblob|changes|last_insert_rowid|sqlite_version|sqlite_source_id)\s*\(/i
    CURRENT_TIME_CONSTANT = /\b(?:CURRENT_TIME|CURRENT_DATE|CURRENT_TIMESTAMP)\b/i
    TIME_FUNCTIONS = %w[date time datetime julianday unixepoch strftime timediff].freeze
    QUOTED_CALLABLE_BUILTINS = [
      *TIME_FUNCTIONS, *%w[random randomblob changes last_insert_rowid sqlite_version sqlite_source_id]
    ].freeze
    CURRENT_TIME_LITERAL = "__litehm_current_time_literal__"
    OTHER_LITERAL = "__litehm_literal__"
    QUOTED_IDENTIFIER = "__litehm_identifier__"
    LOSSY_CONFLICT = /\bON\s+CONFLICT\s+(?:ROLLBACK|FAIL|IGNORE|REPLACE)\b/i

    def initialize(connection, plan)
      @connection = connection
      @plan = plan
    end

    def validate!
      validate_version!
      validate_table_kind!
      validate_dependent_triggers!
      validate_projection!
      validate_recursive_trigger_contract!
      validate_conflict_policies!
      if @connection.first_value("PRAGMA ignore_check_constraints").to_i != 0
        raise UnsupportedObject, "LiteHM requires CHECK constraint enforcement on the runner connection"
      end
      validate_journal_mode!
    end

    def replace_conflict?(sql)
      sanitize_trigger_sql(sql.to_s).match?(/\bON\s+CONFLICT\s+REPLACE\b/i)
    end

    private

    def validate_version!
      actual = Gem::Version.new(@connection.first_value("SELECT sqlite_version()"))
      return if actual >= MINIMUM_SQLITE

      raise VersionUnsupported.new("SQLite #{actual} is unsupported; LiteHM requires #{MINIMUM_SQLITE} or newer with the WAL-reset fix",
        details: { actual: actual.to_s, minimum: MINIMUM_SQLITE.to_s })
    end

    def validate_table_kind!
      sql = @plan.source_manifest.fetch("table_sql")
      return if sql.match?(/\ACREATE\s+TABLE\b/i)

      raise UnsupportedObject, "virtual tables and non-ordinary tables are outside LiteHM's contract"
    end

    def validate_projection!
      @plan.projection.each do |column, expression|
        if nondeterministic_projection?(expression)
          raise UnsupportedObject.new("projection for #{column.inspect} is not deterministic",
            details: { column:, expression: })
        end

        validate_row_local_projection!(column, expression)
      end
    end

    def validate_row_local_projection!(column, expression)
      rows = @connection.execute(<<~SQL)
        EXPLAIN SELECT #{expression}
        FROM #{SQL.identifier(@plan.table)}
        LIMIT 0
      SQL
      opcodes = rows.map { |row| row.fetch(1) }
      validate_function_flags!(column, expression, rows)
      read_cursors = opcodes.count("OpenRead")
      return if (opcodes & NON_ROW_LOCAL_OPCODES).empty? &&
        !opcodes.include?("OpenDup") && read_cursors <= 1

      raise UnsupportedObject.new("projection for #{column.inspect} depends on rows outside the source row",
        details: { column:, expression: })
    rescue SQLite3::SQLException => error
      raise InvalidPlan.new("projection for #{column.inspect} does not compile",
        details: { column:, expression:, sqlite_error: error.message }), cause: error
    end

    def validate_function_flags!(column, expression, rows)
      functions = rows.filter_map do |row|
        next unless %w[Function PureFunc].include?(row.fetch(1))

        match = row.fetch(5).to_s.match(/\A(.+)\((-?\d+)\)\z/)
        [match[1], match[2].to_i] if match
      end
      available = @connection.execute("PRAGMA function_list")
      functions.each do |name, arity|
        implementations = available.select do |entry|
          entry.fetch(0).casecmp?(name) && entry.fetch(2) == "s" && entry.fetch(4).to_i == arity
        end
        next if implementations.any? && implementations.all? do |entry|
          entry.fetch(1) == 1 && (entry.fetch(5).to_i & 0x800).positive?
        end

        raise UnsupportedObject.new("projection for #{column.inspect} uses a function not proven deterministic",
          details: { column:, expression:, function: name })
      end
    end

    def validate_dependent_triggers!
      triggers = @plan.source_manifest.fetch("dependent_triggers", [])
      return if triggers.empty?

      raise UnsupportedObject.new(
        "triggers on other tables depend on #{@plan.table.inspect}; rewrite or remove them before migration",
        details: { triggers: triggers.map { |trigger| trigger.fetch("name") } }
      )
    end

    def validate_conflict_policies!
      sql = sanitize_trigger_sql(@plan.target_manifest.fetch("table_sql"))
      match = sql.match(LOSSY_CONFLICT)
      return unless match

      raise UnsupportedObject.new("target conflict policy #{match[0].inspect} can discard or replace rows",
        details: { policy: match[0] })
    end

    def validate_journal_mode!
      mode = @connection.first_value("PRAGMA journal_mode").to_s.downcase
      return if mode == "wal"

      raise UnsupportedObject.new("online execution requires WAL journal mode; current mode is #{mode.inspect}",
        details: { journal_mode: mode })
    end

    def validate_recursive_trigger_contract!
      source_replace = replace_conflict?(@plan.source_manifest.fetch("table_sql")) ||
        @plan.policy.fetch("source_replace_writes")
      self_mutating_trigger = @plan.source_manifest.fetch("objects").any? do |object|
        next false unless object.fetch("type") == "trigger"

        trigger_writes_table?(object.fetch("sql"))
      end
      return unless source_replace || self_mutating_trigger
      return if @plan.policy.fetch("all_writers_recursive_triggers")

      raise UnsupportedObject,
        "replace-style or self-triggered source writes require all_writers_recursive_triggers: true"
    end

    def trigger_writes_table?(sql)
      table = Regexp.escape(@plan.table)
      qualifier = '(?:["`\[]?main["`\]]?\s*\.\s*)?'
      target = "#{qualifier}[\"`\\[]?#{table}[\"`\\]]?"
      dml = '(?:INSERT(?:\\s+OR\\s+\\w+)?\\s+INTO|REPLACE\\s+INTO|' \
        'UPDATE(?:\\s+OR\\s+\\w+)?|DELETE\\s+FROM)'
      sanitize_trigger_sql(sql).match?(/\b#{dml}\s+#{target}(?![\w])/i)
    end

    def nondeterministic_projection?(expression)
      code = sanitize_sql_expression(expression)
      code.match?(NONDETERMINISTIC_FUNCTION) || code.match?(CURRENT_TIME_CONSTANT) ||
        nondeterministic_time_call?(code)
    end

    def sanitize_sql_expression(expression)
      output = +""
      index = 0
      while index < expression.length
        character = expression[index]
        following = expression[index + 1]
        if character == "'"
          value, index = consume_quoted(expression, index, "'", doubled: true)
          token = %w[now localtime utc].include?(value.downcase) ? CURRENT_TIME_LITERAL : OTHER_LITERAL
          output << token
        elsif character == '"' || character == "`"
          value, index = consume_quoted(expression, index, character, doubled: true)
          output << quoted_identifier_token(value)
        elsif character == "["
          value, index = consume_quoted(expression, index, "]", doubled: false)
          output << quoted_identifier_token(value)
        elsif character == "-" && following == "-"
          index = expression.index("\n", index + 2) || expression.length
          output << " "
        elsif character == "/" && following == "*"
          closing = expression.index("*/", index + 2)
          index = closing ? closing + 2 : expression.length
          output << " "
        else
          output << character
          index += 1
        end
      end
      output
    end

    def quoted_identifier_token(value)
      QUOTED_CALLABLE_BUILTINS.include?(value.downcase) ? value : QUOTED_IDENTIFIER
    end

    def sanitize_trigger_sql(sql)
      output = +""
      index = 0
      while index < sql.length
        character = sql[index]
        following = sql[index + 1]
        if character == "'"
          _value, index = consume_quoted(sql, index, "'", doubled: true)
          output << OTHER_LITERAL
        elsif character == '"' || character == "`"
          value, index = consume_quoted(sql, index, character, doubled: true)
          output << SQL.identifier(value)
        elsif character == "["
          value, index = consume_quoted(sql, index, "]", doubled: false)
          output << SQL.identifier(value)
        elsif character == "-" && following == "-"
          index = sql.index("\n", index + 2) || sql.length
          output << " "
        elsif character == "/" && following == "*"
          closing = sql.index("*/", index + 2)
          index = closing ? closing + 2 : sql.length
          output << " "
        else
          output << character
          index += 1
        end
      end
      output
    end

    def consume_quoted(expression, start, terminator, doubled:)
      value = +""
      index = start + 1
      while index < expression.length
        if expression[index] == terminator
          if doubled && expression[index + 1] == terminator
            value << terminator
            index += 2
          else
            return [value, index + 1]
          end
        else
          value << expression[index]
          index += 1
        end
      end
      [value, index]
    end

    def nondeterministic_time_call?(code)
      matcher = /\b(#{TIME_FUNCTIONS.join('|')})\s*\(/i
      offset = 0
      while (match = matcher.match(code, offset))
        opening = code.index("(", match.begin(0))
        closing = matching_parenthesis(code, opening)
        return true unless closing

        arguments = split_arguments(code[(opening + 1)...closing])
        omitted_time = match[1].casecmp?("strftime") ? arguments.length == 1 : arguments.empty?
        return true if omitted_time || arguments.any? { |argument| argument.include?(CURRENT_TIME_LITERAL) }
        # A column or computed string can evaluate to 'now', 'localtime', or
        # 'utc' on a later write even if today's rows look deterministic.
        return true unless arguments.all? do |argument|
          argument == OTHER_LITERAL || argument.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/)
        end

        offset = opening + 1
      end
      false
    end

    def matching_parenthesis(code, opening)
      depth = 0
      code.each_char.with_index do |character, relative|
        next if relative < opening

        depth += 1 if character == "("
        depth -= 1 if character == ")"
        return relative if depth.zero?
      end
      nil
    end

    def split_arguments(content)
      return [] if content.strip.empty?

      arguments = []
      start = 0
      depth = 0
      content.each_char.with_index do |character, index|
        depth += 1 if character == "("
        depth -= 1 if character == ")"
        next unless character == "," && depth.zero?

        arguments << content[start...index].strip
        start = index + 1
      end
      arguments << content[start..].strip
      arguments
    end
  end
end
