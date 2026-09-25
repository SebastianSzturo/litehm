# frozen_string_literal: true

module LiteHM
  # Parent writes must be decided by the live table, never by a stale shadow or
  # a released archive. Prune those copies before SQLite evaluates FK actions.
  class ForeignKeyProtocol
    VERSION = "live_v1"

    def initialize(connection, plan, names, source_keys:, target_keys:, correspondence:)
      @connection, @plan, @names = connection, plan, names
      @source_keys, @target_keys, @correspondence = source_keys, target_keys, correspondence
    end

    def install(archive: false)
      references = archive ? @plan.source_manifest.fetch("foreign_keys") : @plan.target_manifest.fetch("foreign_keys")
      references.group_by { |reference| reference.fetch("table").tr("A-Z", "a-z") }.each_value do |keys|
        parent = keys.first.fetch("table")
        groups = keys.group_by { |key| key.fetch("id") }.values
        columns = groups.flat_map { |group| referenced_columns(group) }.uniq
        table = @names.fetch(archive ? :archive : :shadow)
        manifest = archive ? @plan.source_manifest : @plan.target_manifest
        require_indexed_access!(table, manifest, groups)
        predicate = groups.map { |group| matching_parent(group, table, manifest) }.join(" OR ")
        body = []
        body << capture_affected_rows(table, predicate) unless archive
        body << "DELETE FROM #{SQL.identifier(table)} WHERE #{predicate};"
        delete_name, update_name = self.class.names(@plan.id, parent)
        create_trigger(delete_name, "DELETE", parent, body.join("\n"))
        update_columns = columns.map { |column| SQL.identifier(column) }.join(", ")
        changed = columns.map do |column|
          "OLD.#{SQL.identifier(column)} IS NOT NEW.#{SQL.identifier(column)}"
        end.join(" OR ")
        create_trigger(update_name, "UPDATE OF #{update_columns}", parent, body.join("\n"), condition: changed)
      end
    end

    def validate_source_access!
      # Recheck target references on resume too: an already-prepared plan may
      # have guards installed by an older version that missed generated keys.
      @plan.target_manifest.fetch("foreign_keys")
        .group_by { |key| [key.fetch("table").tr("A-Z", "a-z"), key.fetch("id")] }
        .each_value { |group| reject_generated_parent_keys!([group]) }
      @plan.source_manifest.fetch("foreign_keys")
        .group_by { |key| key.fetch("table").tr("A-Z", "a-z") }.each_value do |keys|
        require_indexed_access!(@plan.table, @plan.source_manifest,
          keys.group_by { |key| key.fetch("id") }.values)
      end
    end

    def self.names(plan_id, parent)
      digest = Digest::SHA256.hexdigest(parent.tr("A-Z", "a-z"))[0, 8]
      [SQL.artifact("guard_delete_#{digest}", plan_id),
        SQL.artifact("guard_update_#{digest}", plan_id)]
    end

    private

    def reject_generated_parent_keys!(groups)
      groups.each do |group|
        parent = group.first.fetch("table")
        referenced = referenced_columns(group).map { |name| name.tr("A-Z", "a-z") }
        generated = @connection.execute("PRAGMA table_xinfo(#{SQL.literal(parent)})").select do |column|
          column[6].to_i >= 2 && referenced.include?(column[1].tr("A-Z", "a-z"))
        end
        unless generated.empty?
          # UPDATE OF the key does not fire when a generated key changes through
          # its dependencies. Refuse before installing guards or copying rows.
          raise UnsupportedObject.new("generated parent keys are unsupported by the online foreign-key protocol",
            details: { parent:, columns: generated.map { |column| column[1] } })
        end
      end
    end

    def require_indexed_access!(table, manifest, groups)
      reject_generated_parent_keys!(groups)
      # These predicates run in APPLICATION transactions, not in our paced worker.
      # Refuse a full scan even if it happens to be cheap on today's small table.
      candidate = "__litehm_candidate"
      predicate = groups.map { |group| matching_parent(group, candidate, manifest) }.join(" OR ")
      predicate = predicate.gsub(/OLD\."(?:[^"]|"")*"/, "0")
      details = @connection.execute(<<~SQL).map(&:last)
        EXPLAIN QUERY PLAN SELECT 1 FROM #{SQL.identifier(table)} AS #{SQL.identifier(candidate)}
        WHERE #{predicate}
      SQL
      return if details.any? { |detail| detail.start_with?("SEARCH #{candidate} ") } &&
        details.none? { |detail| detail.start_with?("SCAN #{candidate}") }

      raise UnsupportedObject.new(
        "online foreign-key parent handling requires an indexed lookup; unindexed or affinity/collation conversions that scan the child table are unsupported",
        details: { table:, child_columns: groups.map { |group| group.map { |key| key.fetch("from") } }, query_plan: details }
      )
    end

    def create_trigger(name, event, parent, body, condition: nil)
      @connection.execute(<<~SQL)
        CREATE TRIGGER IF NOT EXISTS #{SQL.identifier(name)} BEFORE #{event} ON #{SQL.identifier(parent)}
        #{"WHEN #{condition}" if condition}
        BEGIN #{body} END
      SQL
    end

    def referenced_columns(references)
      references = references.sort_by { |reference| reference.fetch("seq").to_i }
      names = references.map { |reference| reference["to"] }
      return names unless names.any?(&:nil?)

      parent = references.first.fetch("table")
      @connection.execute("PRAGMA table_xinfo(#{SQL.literal(parent)})")
        .select { |row| row[5].to_i.positive? }.sort_by { |row| row[5].to_i }.map { |row| row[1] }
    end

    def matching_parent(references, table, manifest)
      children = references.sort_by { |reference| reference.fetch("seq").to_i }.map { |reference| reference.fetch("from") }
      parents = referenced_columns(references)
      unless children.length == parents.length && parents.any?
        raise UnsupportedObject, "foreign key does not match the parent primary key"
      end
      parent = references.first.fetch("table")
      if parents.length == 1 && integer_rowid_reference?(parent, parents.first, children.first, manifest)
        # The common Rails FK can use the existing child-side index. Both
        # sides have INTEGER affinity and the parent value is always an integer.
        return "#{SQL.identifier(children.first)} = OLD.#{SQL.identifier(parents.first)}"
      end

      # Comparing through the real parent row preserves SQLite's FK semantics,
      # including NOCASE and numeric parents referenced by textual child values.
      # Equal affinities need no unary +; leaving the child as a column lets
      # SQLite use its index. The parent on the left still supplies collation.
      parent_types = @connection.execute("PRAGMA table_xinfo(#{SQL.literal(parent)})").to_h { |row| [row[1].tr("A-Z", "a-z"), row[2]] }
      child_types = manifest.fetch("columns").to_h { |column| [column.fetch("name").tr("A-Z", "a-z"), column.fetch("type")] }
      comparisons = parents.zip(children).map do |parent_column, child|
        column = "__litehm_parent.#{SQL.identifier(parent_column)}"
        strip_affinity = affinity(parent_types.fetch(parent_column.tr("A-Z", "a-z"))) != affinity(child_types.fetch(child.tr("A-Z", "a-z")))
        "#{column} IS OLD.#{SQL.identifier(parent_column)} AND " \
          "#{column} = #{"+" if strip_affinity}#{SQL.identifier(table)}.#{SQL.identifier(child)}"
      end
      "EXISTS (SELECT 1 FROM #{SQL.identifier(parent)} AS __litehm_parent WHERE #{comparisons.join(' AND ')})"
    end

    def affinity(type)
      type = type.to_s.upcase
      return :integer if type.include?("INT")
      return :text if type.match?(/CHAR|CLOB|TEXT/)
      return :blob if type.empty? || type.include?("BLOB")
      return :real if type.match?(/REAL|FLOA|DOUB/)

      :numeric
    end

    def integer_rowid_reference?(parent, parent_column, child, manifest)
      columns = @connection.execute("PRAGMA table_xinfo(#{SQL.literal(parent)})")
      primary = columns.select { |row| row[5].to_i.positive? }
      return false unless primary.length == 1 && primary.first[1].tr("A-Z", "a-z") == parent_column.tr("A-Z", "a-z") &&
        primary.first[2].to_s.upcase == "INTEGER"
      return false if @connection.execute("PRAGMA index_list(#{SQL.literal(parent)})").any? { |row| row[3] == "pk" }

      manifest.fetch("columns").any? do |column|
        column.fetch("name").tr("A-Z", "a-z") == child.tr("A-Z", "a-z") && column.fetch("type").to_s.upcase.include?("INT")
      end
    end

    def capture_affected_rows(table, predicate)
      dirty_keys = @source_keys.each_index.map { |index| SQL.identifier("key_#{index}") }.join(", ")
      source = if @correspondence
        source_columns = @source_keys.each_index.map { |index| SQL.identifier("source_#{index}") }.join(", ")
        target_columns = @target_keys.each_index.map { |index| "target_#{index}" }
        <<~SQL
          SELECT #{source_columns} FROM #{SQL.identifier(@names.fetch(:correspondence))}
          WHERE #{tuple(target_columns)} IN (
            SELECT #{@target_keys.map { |key| SQL.identifier(key) }.join(', ')}
            FROM #{SQL.identifier(table)} WHERE #{predicate}
          )
        SQL
      else
        "SELECT #{@target_keys.map { |key| SQL.identifier(key) }.join(', ')} FROM #{SQL.identifier(table)} WHERE #{predicate}"
      end
      <<~SQL
        INSERT INTO #{SQL.identifier(@names.fetch(:dirty))}(#{dirty_keys})
        #{source.strip}
        ON CONFLICT(#{dirty_keys}) DO NOTHING;
      SQL
    end

    def tuple(columns)
      names = columns.map { |column| SQL.identifier(column) }
      names.length == 1 ? names.first : "(#{names.join(', ')})"
    end
  end
end
