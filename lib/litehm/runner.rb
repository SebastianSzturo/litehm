# frozen_string_literal: true

require "digest"
require "securerandom"

module LiteHM
  class Runner
    BATCH_ROWS = 250
    VALIDATION_CURSOR_KEYS = %w[validation_source_cursor validation_target_cursor].freeze
    TailTooLarge = Class.new(StandardError)
    ExecutionHalted = Class.new(StandardError)

    def initialize(connection, plan)
      @connection = connection
      @connection.prepare_writer_cache!
      @plan = plan
      @store = Store.new(connection)
      @telemetry = Telemetry.new(plan)
      @lease_owner = SecureRandom.uuid
      @write_budgets = Hash.new { |budgets, kind| budgets[kind] = WriteBudget.new(@plan.policy) }
      @names = {
        shadow: SQL.artifact("shadow", plan.id),
        dirty: SQL.artifact("dirty", plan.id),
        work: SQL.artifact("work", plan.id),
        correspondence: SQL.artifact("correspondence", plan.id),
        allocator: SQL.artifact("allocator", plan.id),
        insert_trigger: SQL.artifact("capture_insert", plan.id),
        update_trigger: SQL.artifact("capture_update", plan.id),
        delete_trigger: SQL.artifact("capture_delete", plan.id),
        archive: SQL.artifact("archive", plan.id)
      }
    end

    def run(through: :cut_over, checkpoint: nil, command_state: nil)
      @checkpoint = checkpoint
      @command_state = command_state&.to_s
      authoritative = @store.register(@plan)
      @plan = authoritative
      with_operation_lease { perform_run(through:) }
    end

    def perform_run(through:)
      current = @store.status(@plan.id)
      halt_for_command!(current)
      if current.cut_over?
        cleanup_transient_artifacts
        perform_cleanup if current.phase == "archive_released"
        return @store.receipt(@plan.id)
      end
      if %w[aborting aborted].include?(current.phase)
        raise AbortUnavailable,
          "plan #{@plan.id.inspect} is #{current.phase}; use LiteHM.abort to finish an in-progress abort"
      end

      validate_identity!
      validate_foreign_keys!
      Capabilities.new(@connection, @plan).validate!
      unless phase_at_least?(current.phase, "preparing")
        ensure_artifact_names_available!
        prepare
        checkpoint!(:prepared)
      end
      enforce_resource_budgets!
      repair_artifacts! unless artifacts_valid?
      reconcile_snapshot
      copy_until_complete
      reconcile_snapshot
      validate_all_ranges
      validate_global_snapshot!
      mark_ready
      checkpoint!(:ready)
      return @store.status(@plan.id) if through.to_sym == :ready

      cut_over
    end

    def abort(checkpoint: nil, command_state: nil)
      @checkpoint = checkpoint
      @command_state = command_state&.to_s
      with_operation_lease { perform_abort }
    end

    def perform_abort
      @telemetry.stage = :abort
      status = @store.status(@plan.id)
      raise AbortUnavailable, "plan #{@plan.id.inspect} has already cut over" if status.cut_over?
      return status if status.phase == "aborted"

      if status.phase == "planned"
        fenced_transaction do
          @store.transition(@plan.id, phase: :aborted, retry_action: "forbidden",
            desired_state: :running)
        end
        checkpoint!(:aborted)
        return @store.status(@plan.id)
      end

      validate_identity!

      unless status.phase == "aborting"
        fenced_transaction do
          drop_capture
          drop_parent_guards unless live_foreign_keys?
          @store.transition(@plan.id, phase: :aborting, retry_action: "abort")
        end
        Testing.inject(:after_abort_started, plan_id: @plan.id)
      end
      drain_and_drop_table(@names.fetch(:shadow), @target_keys, before_drop: -> { drop_parent_guards })
      # Artifact loss can bypass the shadow's before_drop callback. Remove any
      # surviving guards before deleting the journal they reference, including
      # when resuming an interrupted abort.
      fenced_transaction { drop_parent_guards }
      drain_and_drop_table(@names.fetch(:dirty), @dirty_keys)
      drain_and_drop_table(@names.fetch(:work), @dirty_keys)
      drain_and_drop_table(@names.fetch(:correspondence), correspondence_source_columns)
      drain_and_drop_table(@names.fetch(:allocator), ["id"])
      fenced_transaction do
        @store.transition(@plan.id, phase: :aborted, retry_action: "forbidden",
          desired_state: :running)
      end
      checkpoint!(:aborted)
      @store.status(@plan.id)
    end

    def cleanup(checkpoint: nil, command_state: nil)
      @checkpoint = checkpoint
      @command_state = command_state&.to_s
      with_operation_lease do
        unless @store.status(@plan.id).cut_over?
          raise AbortUnavailable, "plan #{@plan.id.inspect} has not cut over"
        end
        cleanup_transient_artifacts
        perform_cleanup
      end
    end

    def perform_cleanup
      @telemetry.stage = :cleanup
      status = @store.status(@plan.id)
      raise AbortUnavailable, "plan #{@plan.id.inspect} has not cut over" unless status.cut_over?
      return status if status.phase == "done"

      archive = @names.fetch(:archive)
      unless status.phase == "archive_released"
        durable_receipt = @store.receipt(@plan.id)
        released_receipt = Receipt.new(**durable_receipt.to_h.merge(
          phase: "archive_released", archive_name: nil
        ))
        fenced_transaction do
          @store.transition(@plan.id, phase: :archive_released, receipt: released_receipt,
            archive: { "name" => archive, "state" => "releasing" }, retry_action: "cleanup")
        end
        Testing.inject(:after_archive_release_commit, plan_id: @plan.id)
      end
      source_keys = locator_columns(@plan.source_manifest).map { |column| column.fetch("name") }
      while table_exists?(archive)
        identities = cleanup_identities(archive, source_keys)
        checkpoint_status = fenced_transaction(kind: :cleanup, rows: identities.length) do
          delete_identities(archive, source_keys, identities)
          unless @connection.first_value("SELECT 1 FROM #{SQL.identifier(archive)} LIMIT 1")
            drop_parent_guards
            @connection.execute("DROP TABLE #{SQL.identifier(archive)}")
          end
          @store.touch(@plan.id)
        end
        Testing.inject(:after_cleanup_batch, plan_id: @plan.id)
        deliver_checkpoint!(checkpoint_status, :archive_cleanup)
      end
      fenced_transaction do
        drop_parent_guards
        @store.transition(@plan.id, phase: :done,
          archive: { "name" => archive, "state" => "released" }, retry_action: "forbidden",
          desired_state: :running)
      end
      checkpoint!(:done)
      @store.status(@plan.id)
    end

    def cleanup_transient_artifacts
      drain_and_drop_table(@names.fetch(:correspondence), correspondence_source_columns)
      drain_and_drop_table(@names.fetch(:allocator), ["id"])
    end

    def correspondence_source_columns
      @source_keys ||= locator_columns(@plan.source_manifest).map { |column| column.fetch("name") }
      @source_keys.each_index.map { |index| "source_#{index}" }
    end

    def drain_and_drop_table(name, keys, before_drop: nil)
      while table_exists?(name)
        identities = cleanup_identities(name, keys)
        checkpoint_status = fenced_transaction(kind: :cleanup, rows: identities.length) do
          delete_identities(name, keys, identities)
          unless @connection.first_value("SELECT 1 FROM #{SQL.identifier(name)} LIMIT 1")
            before_drop&.call
            @connection.execute("DROP TABLE #{SQL.identifier(name)}")
          end
          @store.touch(@plan.id)
        end
        Testing.inject(:after_artifact_cleanup_batch, plan_id: @plan.id, table: name)
        deliver_checkpoint!(checkpoint_status, :artifact_cleanup)
      end
    end

    private

    def cleanup_identities(table, keys)
      key_list = keys.map { |key| SQL.identifier(key) }.join(", ")
      identities = @connection.execute(<<~SQL)
        SELECT #{key_list} FROM #{SQL.identifier(table)}
        ORDER BY #{key_list} LIMIT #{@write_budgets[:cleanup].row_limit}
      SQL
      bounded_identities(table, keys, identities, kind: :cleanup)
    end

    def delete_identities(table, keys, identities)
      return if identities.empty?

      @connection.execute(<<~SQL, identities.flatten)
        DELETE FROM #{SQL.identifier(table)}
        WHERE #{tuple_sql(keys)} IN (#{bind_rows(identities.length, keys.length)})
      SQL
    end

    # Size and warm the selected payloads BEFORE acquiring the writer lock.
    # Capture triggers still journal source changes during this read; INSERT
    # projects current source values inside the following write transaction.
    def payload_sizes(table, keys, identities, projection: nil)
      return [{}, []] if identities.empty?

      expressions = projection || @connection.execute("PRAGMA table_xinfo(#{SQL.literal(table)})")
        .reject { |column| column[6].to_i == 1 }.map { |column| SQL.identifier(column[1]) }
      bytes_sql = expressions.map { |expression| "COALESCE(octet_length(#{expression}), 0)" }.join(" + ")
      source_bytes = if projection && table == @plan.table
        @source_payload_bytes_sql ||= @plan.source_manifest.fetch("columns").map do |column|
          "COALESCE(octet_length(#{SQL.identifier(column.fetch('name'))}), 0)"
        end.join(" + ")
      else
        bytes_sql
      end
      key_list = keys.map { |key| SQL.identifier(key) }.join(", ")
      rows = @connection.execute(<<~SQL, identities.flatten)
        SELECT #{key_list}, (#{bytes_sql}), (#{source_bytes}) FROM #{SQL.identifier(table)}
        WHERE #{tuple_sql(keys)} IN (#{bind_rows(identities.length, keys.length)})
      SQL
      maximum = @write_budgets[:control].max_row_bytes
      rows.each do |row|
        # Every caller, including the final tail, must enforce both the source
        # and projected sizes before installing a row in the shadow.
        row_bytes = [row[keys.length].to_i, row.last.to_i].max
        next if row_bytes <= maximum

        raise BusyBudgetExceeded.new("source, projected, or archive row exceeds the online migration payload budget",
          details: { table:, row_bytes:, max_row_bytes: maximum })
      end
      sizes = rows.to_h { |row| [row.first(keys.length), row[keys.length].to_i] }
      if projection && @plan.target_manifest.fetch("columns").any? { |column| column.fetch("hidden", 0).to_i > 1 }
        @generated_row_sizer ||= GeneratedRowSizer.new(@plan)
        # The first read checks both ordinary projections and source payloads.
        # Bound the second read as well: a concurrent writer may grow a value
        # between preflight reads. The fenced recheck sees a stable source.
        @connection.database.execute(<<~SQL, [*identities.flatten, maximum, maximum]) do |row|
          SELECT #{key_list}, #{projection.join(', ')} FROM #{SQL.identifier(table)}
          WHERE #{tuple_sql(keys)} IN (#{bind_rows(identities.length, keys.length)})
            AND (#{bytes_sql}) <= ? AND (#{source_bytes}) <= ?
        SQL
          size = @generated_row_sizer.size(row.drop(keys.length))
          if size > maximum
            raise BusyBudgetExceeded.new("generated target row exceeds the online migration payload budget",
              details: { table:, row_bytes: size, max_row_bytes: maximum })
          end
          sizes[row.first(keys.length)] = size
        end
      end
      [sizes, expressions]
    end

    def warm_rows(table, keys, identities, expressions)
      return if identities.empty?

      @connection.execute(<<~SQL, identities.flatten)
        SELECT #{expressions.join(', ')} FROM #{SQL.identifier(table)}
        WHERE #{tuple_sql(keys)} IN (#{bind_rows(identities.length, keys.length)})
      SQL
    end

    def bounded_identities(table, keys, identities, kind:, projection: nil, extra_sizes: {}, warm: true)
      return identities if identities.empty?

      budget = @write_budgets[kind]
      sizes, expressions = payload_sizes(table, keys, identities, projection:)
      selected = []
      bytes = 0
      identities.each do |identity|
        size = sizes.fetch(identity, 0) + extra_sizes.fetch(identity, 0)
        if [sizes.fetch(identity, 0), extra_sizes.fetch(identity, 0)].max > budget.max_row_bytes
          raise BusyBudgetExceeded.new("row exceeds the online migration payload budget",
            details: { table:, row_bytes: size, max_row_bytes: budget.max_row_bytes })
        end
        break if selected.any? && bytes + size > budget.byte_limit

        selected << identity
        bytes += size
      end
      # A single row may exceed the batch target, but never max_row_bytes.
      # Streaming/prewarming this bounded set avoids cold payload reads while
      # holding the database's sole writer lock.
      if warm
        warm_rows(table, keys, selected, expressions)
        Testing.inject(:batch_selected, plan_id: @plan.id, kind:, rows: selected.length, bytes:)
      end
      selected
    end

    def reconciliation_identities(identities, warm: true)
      previous = target_identities_for(identities)
      sizes, expressions = payload_sizes(@names.fetch(:shadow), @target_keys, previous)
      mappings = source_identity_map_for_targets(previous)
      extra_sizes = previous.to_h do |target|
        source = mappings[CanonicalJSON.dump(ValueCodec.encode_row(target))]
        [source, sizes.fetch(target, 0)]
      end
      selected = bounded_identities(@plan.table, @source_keys, identities,
        kind: :reconcile, projection: @plan.projection.values, extra_sizes:, warm:)
      warm_rows(@names.fetch(:shadow), @target_keys, target_identities_for(selected), expressions) if warm
      selected
    end

    PHASES = %w[planned preparing ready cut_over archive_released done].freeze

    def phase_at_least?(phase, target)
      PHASES.index(phase).to_i >= PHASES.index(target).to_i
    end

    def validate_identity!
      source_pk = locator_columns(@plan.source_manifest)
      target_pk = locator_columns(@plan.target_manifest)
      unless source_pk.any?
        raise UnsupportedObject,
          "source requires a complete primary key or UNIQUE NOT NULL locator"
      end
      @source_keys = source_pk.map { |column| column.fetch("name") }
      if target_pk.empty?
        configure_synthetic_rowid!(source_pk)
      else
        unless source_pk.length == target_pk.length && target_pk.zip(source_pk).all? { |target, source|
            @plan.projection[target.fetch("name")] == SQL.identifier(source.fetch("name"))
          }
          @uses_correspondence = true
        end
        @target_keys = target_pk.map { |column| column.fetch("name") }
      end
      @dirty_keys = @source_keys.each_index.map { |index| "key_#{index}" }

    end

    def configure_synthetic_rowid!(source_locator)
      if @plan.target_manifest.fetch("table_sql").match?(/\bWITHOUT\s+ROWID\b/i)
        raise UnsupportedObject, "WITHOUT ROWID targets require a declared primary key"
      end
      target_names = @plan.target_manifest.fetch("columns").map { |column| column.fetch("name").downcase }
      @synthetic_rowid = %w[rowid _rowid_ oid].find { |candidate| !target_names.include?(candidate) }
      unless @synthetic_rowid
        raise UnsupportedObject, "target shadows every hidden rowid alias"
      end
      @target_keys = [@synthetic_rowid]
      unless source_locator.length == 1 && source_locator.first.fetch("type").to_s.upcase == "INTEGER"
        @uses_correspondence = true
        @allocate_rowid = true
      end
    end

    def validate_foreign_keys!
      validate_inbound_foreign_keys!
      return if outbound_foreign_keys.empty?

      unless @plan.policy.fetch("archive") == "ephemeral"
        raise UnsupportedObject,
          "outbound foreign keys require policy: { archive: :ephemeral }"
      end
      if outbound_foreign_keys.any? { |foreign_key| foreign_key.fetch("table").tr("A-Z", "a-z") == @plan.table.tr("A-Z", "a-z") }
        raise UnsupportedObject, "self-referential foreign keys are not supported by the parent-guard protocol yet"
      end
      parent_replace = outbound_foreign_keys.any? do |foreign_key|
        sql = @connection.first_value(
          "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ? COLLATE NOCASE", [foreign_key.fetch("table")]
        )
        Capabilities.new(@connection, @plan).replace_conflict?(sql)
      end
      if (parent_replace || @plan.policy.fetch("parent_replace_writes")) &&
          !@plan.policy.fetch("all_writers_recursive_triggers")
        raise UnsupportedObject,
          "replace-style parent writes require all_writers_recursive_triggers: true"
      end
      foreign_key_protocol.validate_source_access! if live_foreign_keys?
    end

    def validate_inbound_foreign_keys!
      source_columns = @plan.source_manifest.fetch("columns").to_h { |column| [column.fetch("name").tr("A-Z", "a-z"), column] }
      target_columns = @plan.target_manifest.fetch("columns").to_h { |column| [column.fetch("name").tr("A-Z", "a-z"), column] }
      source_primary_key = primary_key_columns(@plan.source_manifest).map { |column| column.fetch("name") }
      @plan.source_manifest.fetch("inbound_foreign_keys").each do |child|
        child.fetch("references").group_by { |reference| reference.fetch("id") }.each_value do |references|
          references = references.sort_by { |reference| reference.fetch("seq").to_i }
          referenced_columns = references.map do |reference|
            (reference["to"] || source_primary_key.fetch(reference.fetch("seq").to_i)).tr("A-Z", "a-z")
          end
          values_preserved = referenced_columns.all? do |referenced|
            source = source_columns[referenced]
            target = target_columns[referenced]
            source && target && target.fetch("type").to_s.upcase == source.fetch("type").to_s.upcase &&
              @plan.projection[target.fetch("name")] == SQL.identifier(source.fetch("name"))
          end
          source_key = unique_key_signatures(@plan.source_manifest)
            .find { |signature| signature.fetch(:columns) == referenced_columns.sort }
          target_key = unique_key_signatures(@plan.target_manifest).find do |signature|
            signature.fetch(:columns) == referenced_columns.sort &&
              signature.fetch(:collations) == source_key&.fetch(:collations)
          end
          next if values_preserved && source_key && target_key

          raise UnsupportedObject.new(
            "inbound foreign key from #{child.fetch("table").inspect} requires referenced key #{referenced_columns.inspect} to remain exact, unique, and collation-compatible",
            details: { child_table: child.fetch("table"), referenced_columns: referenced_columns,
              source_key: source_key, target_key: target_key }
          )
        end
      end
    end

    def unique_key_signatures(manifest)
      signatures = manifest.fetch("indexes").filter_map do |index|
        next unless index.fetch("unique", 0).to_i == 1
        next unless index.fetch("partial", 0).to_i.zero?

        parts = index.fetch("columns").select { |part| part.fetch("key", 0).to_i == 1 }
          .sort_by { |part| part.fetch("seqno").to_i }
        next if parts.empty? || parts.any? { |part| part["name"].nil? }

        # Uniqueness is independent of key order, but each collation must stay
        # attached to its column when comparing inbound FK guarantees.
        parts = parts.sort_by { |part| part.fetch("name").tr("A-Z", "a-z") }
        { columns: parts.map { |part| part.fetch("name").tr("A-Z", "a-z") },
          collations: parts.map { |part| part.fetch("coll", "BINARY").to_s.tr("a-z", "A-Z") } }
      end
      primary = primary_key_columns(manifest).map { |column| column.fetch("name").tr("A-Z", "a-z") }.sort
      if primary.any? && signatures.none? { |signature| signature.fetch(:columns) == primary }
        signatures << { columns: primary, collations: Array.new(primary.length, "BINARY") }
      end
      signatures
    end

    def primary_key_columns(manifest)
      manifest.fetch("columns").select { |column| column.fetch("pk", 0).to_i.positive? }
        .sort_by { |column| column.fetch("pk").to_i }
    end

    def locator_columns(manifest)
      primary_key = primary_key_columns(manifest)
      return primary_key unless primary_key.empty? || nullable_ordinary_primary_key?(manifest, primary_key)

      columns = manifest.fetch("columns").to_h { |column| [column.fetch("name"), column] }
      manifest.fetch("indexes").each do |index|
        next unless index.fetch("unique", 0).to_i == 1
        next unless index.fetch("partial", 0).to_i.zero?

        key_parts = index.fetch("columns").select { |part| part.fetch("key", 0).to_i == 1 }
          .sort_by { |part| part.fetch("seqno").to_i }
        next if key_parts.empty? || key_parts.any? { |part| part.fetch("cid", -1).to_i.negative? }

        locator = key_parts.map { |part| columns.fetch(part.fetch("name")) }
        return locator if locator.all? do |column|
          column.fetch("notnull", 0).to_i == 1 && column.fetch("hidden", 0).to_i.zero?
        end
      end
      if @plan.policy.fetch("allow_bare_rowid") && !manifest.fetch("table_sql").match?(/\bWITHOUT\s+ROWID\b/i)
        names = manifest.fetch("columns").map { |column| column.fetch("name").downcase }
        alias_name = %w[rowid _rowid_ oid].find { |candidate| !names.include?(candidate) }
        return [{ "name" => alias_name, "type" => "INTEGER", "notnull" => 1, "pk" => 1 }] if alias_name
      end
      []
    end

    def nullable_ordinary_primary_key?(manifest, columns)
      return false if manifest.fetch("table_sql").match?(/\bWITHOUT\s+ROWID\b/i)
      if columns.length == 1 && columns.first.fetch("type").to_s.upcase == "INTEGER"
        has_pk_index = manifest.fetch("indexes").any? { |index| index.fetch("origin", "") == "pk" }
        return false unless has_pk_index
      end

      columns.any? { |column| column.fetch("notnull", 0).to_i.zero? }
    end

    def prepare
      fenced_transaction do
        ensure_source_unchanged!
        ensure_artifact_names_available!
        @connection.busy_timeout_ms = @plan.policy.fetch("busy_timeout_ms")
        create_shadow
        create_parent_guards
        create_dirty_table
        create_work_table
        create_correspondence_table
        create_allocator_table
        create_capture
        @store.transition(@plan.id, phase: :preparing,
          progress: { "copy_cursor" => nil, "copied_rows" => 0, "dirty_rows" => 0,
            "copy_upper_bound" => copy_upper_bound, "copy_lower_bound" => copy_lower_bound,
            "artifact_hash" => artifact_hash, "capture_repairs" => 0 })
      end
      Testing.inject(:after_prepare_commit, plan_id: @plan.id)
    end

    def ensure_source_unchanged!
      actual = SchemaReader.new(@connection).read(@plan.table).fetch("hash")
      return if actual == @plan.source_hash

      raise SchemaDrift.new("source schema changed after planning",
        details: { planned: @plan.source_hash, actual: })
    end

    def create_shadow
      return if table_exists?(@names.fetch(:shadow))

      @connection.execute(rewrite_table_name(@plan.target_manifest.fetch("table_sql"), @names.fetch(:shadow)))
      @plan.target_manifest.fetch("indexes").each do |index|
        next unless index["sql"]

        physical = SQL.artifact("index_#{index.fetch("name")}", @plan.id)
        @connection.execute(SQL.rewrite_index(index.fetch("sql"), physical, @names.fetch(:shadow)))
      end
    end

    def create_parent_guards
      return foreign_key_protocol.install if live_foreign_keys?

      outbound_foreign_keys.group_by { |foreign_key| foreign_key.fetch("table") }.each do |parent, keys|
        parent_columns = keys.map { |foreign_key| foreign_key.fetch("to") }.compact.uniq
        if keys.any? { |foreign_key| foreign_key["to"].nil? }
          parent_columns |= table_primary_key_names(parent)
        end
        delete_name, update_name = parent_guard_names(parent)
        message = "LiteHM #{@plan.id}: parent key is frozen"
        unless trigger_exists?(delete_name)
          @connection.execute(<<~SQL)
            CREATE TRIGGER #{SQL.identifier(delete_name)} BEFORE DELETE ON #{SQL.identifier(parent)}
            BEGIN SELECT RAISE(ABORT, #{SQL.literal(message)}); END
          SQL
        end
        unless trigger_exists?(update_name)
          columns = parent_columns.map { |column| SQL.identifier(column) }.join(", ")
          @connection.execute(<<~SQL)
            CREATE TRIGGER #{SQL.identifier(update_name)} BEFORE UPDATE OF #{columns} ON #{SQL.identifier(parent)}
            BEGIN SELECT RAISE(ABORT, #{SQL.literal(message)}); END
          SQL
        end
      end
    end

    def drop_parent_guards
      outbound_foreign_keys.map { |foreign_key| foreign_key.fetch("table") }.uniq.each do |parent|
        parent_guard_names(parent).each do |name|
          @connection.execute("DROP TRIGGER IF EXISTS #{SQL.identifier(name)}")
        end
      end
    end

    def parent_guard_names(parent)
      return ForeignKeyProtocol.names(@plan.id, parent) if live_foreign_keys?

      digest = Digest::SHA256.hexdigest(parent)[0, 8]
      [SQL.artifact("guard_delete_#{digest}", @plan.id),
        SQL.artifact("guard_update_#{digest}", @plan.id)]
    end

    def live_foreign_keys?
      @plan.compiler["foreign_key_protocol"] == ForeignKeyProtocol::VERSION
    end

    def foreign_key_protocol
      ForeignKeyProtocol.new(@connection, @plan, @names,
        source_keys: @source_keys, target_keys: @target_keys, correspondence: @uses_correspondence)
    end

    def table_primary_key_names(table)
      rows = @connection.execute("PRAGMA table_xinfo(#{SQL.literal(table)})")
      rows.select { |row| row[5].to_i.positive? }.sort_by { |row| row[5].to_i }.map { |row| row[1] }
    end

    def outbound_foreign_keys
      @outbound_foreign_keys ||= begin
        rows = @plan.source_manifest.fetch("foreign_keys") + @plan.target_manifest.fetch("foreign_keys")
        rows.uniq { |row| %w[table from to on_update on_delete match].map { |key| row[key] } }
      end
    end

    def create_dirty_table
      definitions = @dirty_keys.map { |name| SQL.identifier(name) }.join(",\n  ")
      primary_key = @dirty_keys.map { |name| SQL.identifier(name) }.join(", ")
      @connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SQL.identifier(@names.fetch(:dirty))} (
          #{definitions},
          PRIMARY KEY (#{primary_key})
        ) WITHOUT ROWID
      SQL
    end

    def create_work_table
      definitions = @dirty_keys.map { |name| SQL.identifier(name) }.join(",\n  ")
      primary_key = @dirty_keys.map { |name| SQL.identifier(name) }.join(", ")
      @connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SQL.identifier(@names.fetch(:work))} (
          #{definitions},
          stage INTEGER NOT NULL DEFAULT 0 CHECK (stage IN (0, 1)),
          PRIMARY KEY (#{primary_key})
        ) WITHOUT ROWID
      SQL
    end

    def create_correspondence_table
      return unless @uses_correspondence

      source_columns = @source_keys.each_index.map { |index| SQL.identifier("source_#{index}") }
      target_columns = @target_keys.each_index.map { |index| SQL.identifier("target_#{index}") }
      definitions = [*source_columns, *target_columns].join(",\n  ")
      @connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SQL.identifier(@names.fetch(:correspondence))} (
          #{definitions},
          PRIMARY KEY (#{source_columns.join(', ')}),
          UNIQUE (#{target_columns.join(', ')})
        ) WITHOUT ROWID
      SQL
    end

    def create_allocator_table
      return unless @allocate_rowid

      @connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS #{SQL.identifier(@names.fetch(:allocator))} (
          id INTEGER PRIMARY KEY AUTOINCREMENT
        )
      SQL
    end

    def create_capture
      table = SQL.identifier(@plan.table)
      trigger(:insert_trigger, "AFTER INSERT", "NEW")
      trigger(:delete_trigger, "AFTER DELETE", "OLD")
      return if trigger_exists?(@names.fetch(:update_trigger))

      @connection.execute(<<~SQL)
        CREATE TRIGGER #{SQL.identifier(@names.fetch(:update_trigger))}
        AFTER UPDATE ON #{table}
        BEGIN
          #{dirty_insert("OLD")};
          #{dirty_insert("NEW")};
        END
      SQL
    end

    def trigger(key, timing, prefix)
      name = @names.fetch(key)
      return if trigger_exists?(name)

      @connection.execute(<<~SQL)
        CREATE TRIGGER #{SQL.identifier(name)}
        #{timing} ON #{SQL.identifier(@plan.table)}
        BEGIN
          #{dirty_insert(prefix)};
        END
      SQL
    end

    def dirty_insert(prefix)
      columns = @dirty_keys.map { |name| SQL.identifier(name) }.join(", ")
      values = @source_keys.map { |name| "#{prefix}.#{SQL.identifier(name)}" }.join(", ")
      conflict = @dirty_keys.map { |name| SQL.identifier(name) }.join(", ")
      "INSERT INTO #{SQL.identifier(@names.fetch(:dirty))}(#{columns}) VALUES (#{values}) " \
        "ON CONFLICT(#{conflict}) DO NOTHING"
    end

    def copy_until_complete
      @telemetry.stage = :copy
      loop do
        copied = begin
          copy_batch
        rescue CaptureLost => error
          @telemetry.retrying(reason: "capture_lost", error:)
          repair_artifacts!
          retry
        end
        break if copied.zero?
      end
    end

    def copy_batch(retry_after_reconcile: true)
      @telemetry.stage = :copy
      status = @store.status(@plan.id)
      unless status.progress.key?("copy_upper_bound")
        # Upgrade a durable plan created by an older runner. Source capture is
        # already installed, so rows beyond this frontier remain journaled.
        fenced_transaction do
          @store.touch(@plan.id, progress: status.progress.merge("copy_upper_bound" => copy_upper_bound))
        end
        status = @store.status(@plan.id)
      end
      upper = status.progress["copy_upper_bound"]
      return 0 unless upper

      upper = ValueCodec.decode_row(upper)
      encoded_cursor = status.progress.fetch("copy_cursor", nil)
      cursor = encoded_cursor && ValueCodec.decode_row(encoded_cursor)
      source_locator = tuple_sql(@source_keys)
      source_key_list = @source_keys.map { |name| SQL.identifier(name) }.join(", ")
      where = "WHERE #{source_locator} <= #{bind_tuple(@source_keys.length)}"
      binds = upper
      unless cursor.nil?
        where += " AND #{source_locator} > #{bind_tuple(@source_keys.length)}"
        binds += cursor
      end
      identities = @connection.execute(<<~SQL, binds)
        SELECT #{source_key_list} FROM #{SQL.identifier(@plan.table)}
        #{where}
        ORDER BY #{source_key_list}
        LIMIT #{@write_budgets[:copy].row_limit}
      SQL
      identities = bounded_identities(@plan.table, @source_keys, identities,
        kind: :copy, projection: @plan.projection.values)

      checkpoint_status = nil
      fenced_transaction(kind: :copy, rows: -> { identities.length }) do
        raise CaptureLost, "LiteHM artifacts changed during copy" unless artifacts_valid?
        identities = bounded_identities(@plan.table, @source_keys, identities,
          kind: :copy, projection: @plan.projection.values, warm: false)
        unless identities.empty?
          insert_projected_rows(identities)
          @store.transition(@plan.id, phase: :preparing,
            progress: status.progress.merge(
              "copy_cursor" => ValueCodec.encode_row(identities.last),
              "copied_rows" => status.progress.fetch("copied_rows", 0) + identities.length,
              **dirty_progress
            ))
          checkpoint_status = @store.status(@plan.id)
        end
      end
      Testing.inject(:after_copy_batch_commit, plan_id: @plan.id, rows: identities.length,
        cursor: identities.last) unless identities.empty?
      deliver_checkpoint!(checkpoint_status, :copy) unless identities.empty?
      enforce_resource_budgets!
      identities.length
    rescue SQLite3::ConstraintException => error
      if retry_after_reconcile
        @telemetry.retrying(reason: "target_constraint", attempt: 1, error:)
        reconcile_snapshot
        return copy_batch(retry_after_reconcile: false)
      end

      raise DataIncompatible.new("source projection violates a target constraint during copy",
        details: { sqlite_error: error.message }), cause: error
    end

    def copy_upper_bound
      copy_bound("DESC")
    end

    # Only used to estimate copy progress in the engine; the copy itself is
    # bounded by copy_upper_bound alone.
    def copy_lower_bound
      copy_bound("ASC")
    end

    def copy_bound(direction)
      columns = @source_keys.map { |key| SQL.identifier(key) }
      row = @connection.execute(<<~SQL).first
        SELECT #{columns.join(', ')} FROM #{SQL.identifier(@plan.table)}
        ORDER BY #{columns.map { |column| "#{column} #{direction}" }.join(', ')} LIMIT 1
      SQL
      row && ValueCodec.encode_row(row)
    end

    def reconcile_snapshot
      @telemetry.stage = :reconcile
      pending_at_start = dirty_count + @connection.first_value(
        "SELECT COUNT(*) FROM #{SQL.identifier(@names.fetch(:work))}"
      )
      return if pending_at_start.zero?

      installed = 0
      loop do
        count = begin
          reconcile_batch
        rescue CaptureLost => error
          @telemetry.retrying(reason: "capture_lost", error:)
          repair_artifacts!
          copy_until_complete
          retry
        end
        break if count.zero?

        installed += @reconciled_insertions
        # Finish a finite generation. Waiting for the live journal to remain
        # empty across a scheduling pause would starve forever under traffic.
        break if installed >= pending_at_start && !@connection.first_value(
          "SELECT 1 FROM #{SQL.identifier(@names.fetch(:work))} LIMIT 1"
        )
      end
    end

    def reconcile_batch(conflict_retries: 0)
      @telemetry.stage = :reconcile
      @reconciled_insertions = 0
      raise CaptureLost, "LiteHM artifacts changed during reconciliation" unless artifacts_valid?
      dirty_key_list = @dirty_keys.map { |name| SQL.identifier(name) }.join(", ")
      if !@connection.first_value("SELECT 1 FROM #{SQL.identifier(@names.fetch(:work))} LIMIT 1") &&
          @connection.first_value("SELECT 1 FROM #{SQL.identifier(@names.fetch(:dirty))} LIMIT 1")
        fenced_transaction { fold_dirty_into_work(dirty_key_list) }
      end
      budget = @write_budgets[:reconcile]
      stage = 0
      identities = @connection.execute(<<~SQL)
        SELECT #{dirty_key_list} FROM #{SQL.identifier(@names.fetch(:work))}
        WHERE stage = 0 ORDER BY #{dirty_key_list} LIMIT #{budget.row_limit}
      SQL
      if identities.empty?
        stage = 1
        identities = @connection.execute(<<~SQL)
          SELECT #{dirty_key_list} FROM #{SQL.identifier(@names.fetch(:work))}
          WHERE stage = 1 ORDER BY #{dirty_key_list} LIMIT #{budget.row_limit}
        SQL
      end
      return 0 if identities.empty?

      identities = reconciliation_identities(identities)
      checkpoint_status = nil
      fenced_transaction(kind: :reconcile, rows: -> { identities.length }) do
        raise CaptureLost, "LiteHM artifacts changed during reconciliation" unless artifacts_valid?
        identities = reconciliation_identities(identities, warm: false)
        if stage.zero?
          target_identities = target_identities_for(identities)
          delete_identities(@names.fetch(:shadow), @target_keys, target_identities)
          delete_correspondence(identities) if @uses_correspondence
          @connection.execute(
            "UPDATE #{SQL.identifier(@names.fetch(:work))} SET stage = 1 WHERE #{tuple_sql(@dirty_keys)} IN (#{bind_rows(identities.length, @dirty_keys.length)})",
            identities.flatten
          )
        else
          insert_projected_rows(identities)
          delete_identities(@names.fetch(:work), @dirty_keys, identities)
          # Ready-tail draining may revisit previously validated ranges. Prove
          # every newly installed batch, including target foreign keys.
          validate_reconciled_identities!(identities, current_target_identities_for(identities), [])
        end
        progress = @store.status(@plan.id).progress.reject do |key, _value|
          VALIDATION_CURSOR_KEYS.include?(key)
        end
        checkpoint_status = @store.touch(@plan.id, progress: progress.merge(dirty_progress))
      end
      @reconciled_insertions = identities.length if stage == 1
      Testing.inject(:after_reconcile_batch_commit, plan_id: @plan.id, rows: identities.length)
      deliver_checkpoint!(checkpoint_status, :reconcile)
      enforce_resource_budgets!
      identities.length
    rescue SQLite3::ConstraintException => error
      # A unique-key rotation can span a new journal generation. Clear the
      # newly dirty participants before retrying inserts into the old target.
      if conflict_retries < 3 && @connection.first_value("SELECT 1 FROM #{SQL.identifier(@names.fetch(:dirty))} LIMIT 1")
        @telemetry.retrying(reason: "target_constraint", attempt: conflict_retries + 1, error:)
        fenced_transaction { fold_dirty_into_work(dirty_key_list) }
        return reconcile_batch(conflict_retries: conflict_retries + 1)
      end
      raise DataIncompatible.new("current source state violates a target constraint during reconciliation",
        details: { sqlite_error: error.message }), cause: error
    end

    def fold_dirty_into_work(key_list, limit: BATCH_ROWS)
      identities = @connection.execute(<<~SQL)
        SELECT #{key_list} FROM #{SQL.identifier(@names.fetch(:dirty))}
        ORDER BY #{key_list} LIMIT #{Integer(limit)}
      SQL
      return 0 if identities.empty?

      columns = [key_list, "stage"].join(", ")
      values = identities.map { "(#{Array.new(@dirty_keys.length, '?').join(', ')}, 0)" }.join(", ")
      conflict = @dirty_keys.map { |name| SQL.identifier(name) }.join(", ")
      @connection.execute(<<~SQL, identities.flatten)
        INSERT INTO #{SQL.identifier(@names.fetch(:work))} (#{columns}) VALUES #{values}
        ON CONFLICT(#{conflict}) DO NOTHING
      SQL
      @connection.execute(<<~SQL, identities.flatten)
        DELETE FROM #{SQL.identifier(@names.fetch(:dirty))}
        WHERE #{tuple_sql(@dirty_keys)} IN (#{bind_rows(identities.length, @dirty_keys.length)})
      SQL
      Testing.inject(:dirty_fold, plan_id: @plan.id, rows: identities.length)
      identities.length
    end

    def target_identities_for(source_identities)
      return source_identities unless @uses_correspondence

      mappings = target_identity_map_for_sources(source_identities)
      source_identities.filter_map do |source|
        mappings[CanonicalJSON.dump(ValueCodec.encode_row(source))]
      end
    end

    def target_identity_map_for_sources(source_identities)
      return {} if source_identities.empty?

      source_columns = @source_keys.each_index.map { |index| "source_#{index}" }
      target_columns = @target_keys.each_index.map { |index| "target_#{index}" }
      rows = @connection.execute(<<~SQL, source_identities.flatten)
        SELECT #{[*source_columns, *target_columns].map { |name| SQL.identifier(name) }.join(', ')}
        FROM #{SQL.identifier(@names.fetch(:correspondence))}
        WHERE #{tuple_sql(source_columns)} IN (#{bind_rows(source_identities.length, source_columns.length)})
      SQL
      rows.to_h do |row|
        source = row.first(@source_keys.length)
        target = row.drop(@source_keys.length)
        [CanonicalJSON.dump(ValueCodec.encode_row(source)), target]
      end
    end

    def current_target_identities_for(source_identities)
      return [] if source_identities.empty?

      current_sources = @connection.execute(<<~SQL, source_identities.flatten)
        SELECT #{@source_keys.map { |name| SQL.identifier(name) }.join(', ')}
        FROM #{SQL.identifier(@plan.table)}
        WHERE #{tuple_sql(@source_keys)} IN (#{bind_rows(source_identities.length, @source_keys.length)})
        ORDER BY #{@source_keys.map { |name| SQL.identifier(name) }.join(', ')}
      SQL
      @uses_correspondence ? target_identities_for(current_sources) : current_sources
    end

    def validate_reconciled_identities!(source_identities, target_identities, previous_target_identities)
      return if source_identities.empty?

      source_key_aliases = @source_keys.each_with_index.map do |name, index|
        "#{SQL.identifier(name)} AS #{SQL.identifier("__litehm_source_key_#{index}")}"
      end
      projection_aliases = @plan.projection.map do |name, expression|
        "#{expression} AS #{SQL.identifier(name)}"
      end
      source_rows = @connection.execute(<<~SQL, source_identities.flatten)
        SELECT #{[*source_key_aliases, *projection_aliases].join(', ')}
        FROM #{SQL.identifier(@plan.table)}
        WHERE #{tuple_sql(@source_keys)} IN (#{bind_rows(source_identities.length, @source_keys.length)})
        ORDER BY #{@source_keys.map { |name| SQL.identifier(name) }.join(', ')}
      SQL
      expected_target_ids = current_target_identities_for(source_identities)
      unless expected_target_ids == target_identities
        raise ValidationFailed, "final target correspondence changed during reconciliation"
      end
      target_rows = if target_identities.empty?
        []
      else
        columns = [*@target_keys, *@plan.projection.keys].map { |name| SQL.identifier(name) }.join(", ")
        @connection.execute(<<~SQL, target_identities.flatten)
          SELECT #{columns} FROM #{SQL.identifier(@names.fetch(:shadow))}
          WHERE #{tuple_sql(@target_keys)} IN (#{bind_rows(target_identities.length, @target_keys.length)})
          ORDER BY #{@target_keys.map { |name| SQL.identifier(name) }.join(', ')}
        SQL
      end
      validate_batch_rows!(source_rows, target_identities, target_rows, nil)

      current_keys = target_identities.to_h do |identity|
        [CanonicalJSON.dump(ValueCodec.encode_row(identity)), true]
      end
      stale = previous_target_identities.reject do |identity|
        current_keys.key?(CanonicalJSON.dump(ValueCodec.encode_row(identity)))
      end
      unless stale.empty?
        remaining = @connection.first_value(<<~SQL, stale.flatten)
          SELECT COUNT(*) FROM #{SQL.identifier(@names.fetch(:shadow))}
          WHERE #{tuple_sql(@target_keys)} IN (#{bind_rows(stale.length, @target_keys.length)})
        SQL
        raise ValidationFailed, "stale target rows remain after final reconciliation" unless remaining.zero?
      end
      validate_target_foreign_keys_for!(target_identities, table: @names.fetch(:shadow))
    end

    def validate_target_foreign_keys_for!(target_identities, table:)
      return if target_identities.empty?

      @plan.target_manifest.fetch("foreign_keys").group_by { |foreign_key| foreign_key.fetch("id") }
        .each_value do |references|
          references = references.sort_by { |reference| reference.fetch("seq").to_i }
          parent = references.first.fetch("table")
          parent_columns = references.map { |reference| reference["to"] }
          parent_columns = table_primary_key_names(parent) if parent_columns.any?(&:nil?)
          child_columns = references.map { |reference| reference.fetch("from") }
          present = child_columns.map { |column| "child.#{SQL.identifier(column)} IS NOT NULL" }.join(" AND ")
          equality = child_columns.zip(parent_columns).map do |child, parent_column|
            "parent.#{SQL.identifier(parent_column)} = +child.#{SQL.identifier(child)}"
          end.join(" AND ")
          locator_parts = @target_keys.map { |key| "child.#{SQL.identifier(key)}" }
          locator = locator_parts.length == 1 ? locator_parts.first : "(#{locator_parts.join(', ')})"
          violation = @connection.first_value(<<~SQL, target_identities.flatten)
            SELECT 1 FROM #{SQL.identifier(table)} AS child
            WHERE #{locator}
              IN (#{bind_rows(target_identities.length, @target_keys.length)})
              AND #{present}
              AND NOT EXISTS (
                SELECT 1 FROM #{SQL.identifier(parent)} AS parent WHERE #{equality}
              )
            LIMIT 1
          SQL
          raise ValidationFailed, "final reconciled rows violate a target foreign key" if violation
        end
    end

    def upsert_correspondence(source_identities)
      return unless @uses_correspondence
      return if @allocate_rowid
      return if source_identities.empty?

      source_columns = @source_keys.each_index.map { |index| "source_#{index}" }
      target_columns = @target_keys.each_index.map { |index| "target_#{index}" }
      all_columns = [*source_columns, *target_columns].map { |name| SQL.identifier(name) }.join(", ")
      source_expressions = @source_keys.map { |name| SQL.identifier(name) }
      target_expressions = @target_keys.map { |name| @plan.projection.fetch(name) }
      conflict = source_columns.map { |name| SQL.identifier(name) }.join(", ")
      updates = target_columns.map do |name|
        quoted = SQL.identifier(name)
        "#{quoted} = excluded.#{quoted}"
      end.join(", ")
      @connection.execute(<<~SQL, source_identities.flatten)
        INSERT INTO #{SQL.identifier(@names.fetch(:correspondence))} (#{all_columns})
        SELECT #{[*source_expressions, *target_expressions].join(', ')}
        FROM #{SQL.identifier(@plan.table)}
        WHERE #{tuple_sql(@source_keys)} IN (#{bind_rows(source_identities.length, @source_keys.length)})
        ON CONFLICT(#{conflict}) DO UPDATE SET #{updates}
      SQL
    end

    def delete_correspondence(source_identities)
      return unless @uses_correspondence
      return if @allocate_rowid
      return if source_identities.empty?

      source_columns = @source_keys.each_index.map { |index| "source_#{index}" }
      @connection.execute(<<~SQL, source_identities.flatten)
        DELETE FROM #{SQL.identifier(@names.fetch(:correspondence))}
        WHERE #{tuple_sql(source_columns)} IN (#{bind_rows(source_identities.length, source_columns.length)})
      SQL
    end

    def ensure_allocations(source_identities)
      return unless @allocate_rowid

      source_columns = @source_keys.each_index.map { |index| "source_#{index}" }
      source_identities.each do |identity|
        exists = @connection.first_value(<<~SQL, identity)
          SELECT 1 FROM #{SQL.identifier(@names.fetch(:correspondence))}
          WHERE #{tuple_sql(source_columns)} = #{bind_tuple(source_columns.length)}
        SQL
        next if exists

        @connection.execute("INSERT INTO #{SQL.identifier(@names.fetch(:allocator))} DEFAULT VALUES")
        rowid = @connection.first_value("SELECT last_insert_rowid()")
        columns = [*source_columns, "target_0"].map { |name| SQL.identifier(name) }.join(", ")
        @connection.execute(<<~SQL, [*identity, rowid])
          INSERT INTO #{SQL.identifier(@names.fetch(:correspondence))} (#{columns})
          VALUES (#{Array.new(identity.length + 1, '?').join(', ')})
        SQL
      end
    end

    def insert_projected_rows(source_identities)
      return if source_identities.empty?

      if @allocate_rowid
        ensure_allocations(source_identities)
        source_identities.each do |identity|
          rowid = target_identities_for([identity]).fetch(0).fetch(0)
          @connection.execute(<<~SQL, [rowid, *identity])
            INSERT INTO #{SQL.identifier(@names.fetch(:shadow))} (#{insert_columns_sql})
            SELECT ?, #{@plan.projection.values.join(', ')}
            FROM #{SQL.identifier(@plan.table)}
            WHERE #{tuple_sql(@source_keys)} = #{bind_tuple(@source_keys.length)}
            ON CONFLICT(#{SQL.identifier(@synthetic_rowid)}) #{upsert_clause}
          SQL
        end
      else
        @connection.execute(<<~SQL, source_identities.flatten)
          INSERT INTO #{SQL.identifier(@names.fetch(:shadow))} (#{insert_columns_sql})
          SELECT #{insert_expressions_sql} FROM #{SQL.identifier(@plan.table)}
          WHERE #{tuple_sql(@source_keys)} IN (#{bind_rows(source_identities.length, @source_keys.length)})
          ON CONFLICT(#{@target_keys.map { |name| SQL.identifier(name) }.join(', ')}) #{upsert_clause}
        SQL
        upsert_correspondence(source_identities) if @uses_correspondence
      end
    end

    def upsert_clause
      assignments = update_assignments
      assignments.empty? ? "DO NOTHING" : "DO UPDATE SET #{assignments}"
    end

    def mark_ready
      @telemetry.stage = :readiness
      Testing.inject(:before_ready_acquire, plan_id: @plan.id)
      attempts = 0
      started_at = monotonic_time
      begin
        attempts += 1
        fenced_transaction do
          hold_started = monotonic_time
          raise CaptureLost, "LiteHM artifacts changed before ready" unless artifacts_valid?
          ensure_source_unchanged!
          tail = reconcile_until_clean_in_transaction
          Testing.inject(:before_final_validation, plan_id: @plan.id,
            database: @connection.database, target_identities: tail.fetch(1))
          validate_reconciled_identities!(*tail)
          hold_ms = ((monotonic_time - hold_started) * 1_000).round
          if tail.first.any? && hold_ms > @plan.policy.fetch("cutover_hold_ms")
            raise BusyBudgetExceeded, "ready writer hold took #{hold_ms}ms"
          end
          @store.transition(@plan.id, phase: :ready,
            progress: @store.status(@plan.id).progress.merge(dirty_progress))
        end
      rescue TailTooLarge, BusyBudgetExceeded => error
        elapsed_ms = ((monotonic_time - started_at) * 1_000).round
        exhausted = attempts >= @plan.policy.fetch("max_ready_batches") ||
          elapsed_ms >= @plan.policy.fetch("max_cutover_elapsed_ms")
        if exhausted
          raise BusyBudgetExceeded.new("ready budgets exhausted with preparation intact",
            details: { attempts:, elapsed_ms:, last_error: error.message }), cause: error
        end
        @telemetry.retrying(reason: "ready_tail", attempt: attempts, error:)
        reconcile_batch
        @telemetry.stage = :readiness
        retry
      rescue SQLite3::ConstraintException => error
        raise DataIncompatible.new("final source state maps multiple rows to one target identity",
          details: { sqlite_error: error.message }), cause: error
      end
      Testing.inject(:after_ready_commit, plan_id: @plan.id)
    end

    def validate_global_snapshot!
      reconcile_snapshot
      validate_all_target_ranges
    end

    def validate_all_ranges
      @telemetry.stage = :validate_source
      Testing.inject(:before_validate_all_ranges, plan_id: @plan.id)
      encoded_cursor = @store.status(@plan.id).progress["validation_source_cursor"]
      cursor = encoded_cursor && ValueCodec.decode_row(encoded_cursor)
      loop do
        source_rows = target_rows = ids = nil
        Testing.inject(:before_validate_source_batch, plan_id: @plan.id, cursor:)
        @connection.transaction(:deferred) do
          predicate = cursor.nil? ? "" : "WHERE #{tuple_sql(@source_keys)} > #{bind_tuple(@source_keys.length)}"
          binds = cursor.nil? ? [] : cursor
          bound = @store.status(@plan.id).progress["copy_upper_bound"]
          if bound
            predicate += predicate.empty? ? "WHERE " : " AND "
            predicate += "#{tuple_sql(@source_keys)} <= #{bind_tuple(@source_keys.length)}"
            binds += ValueCodec.decode_row(bound)
          else
            predicate = "WHERE 0"
            binds = []
          end
          source_key_aliases = @source_keys.each_with_index.map do |name, index|
            "#{SQL.identifier(name)} AS #{SQL.identifier("__litehm_source_key_#{index}")}"
          end
          projection_aliases = @plan.projection.map do |name, expression|
            "#{expression} AS #{SQL.identifier(name)}"
          end
          aliases = [*source_key_aliases, *projection_aliases].join(", ")
          source_rows = @connection.execute(<<~SQL, binds)
            SELECT #{aliases} FROM #{SQL.identifier(@plan.table)}
            #{predicate}
            ORDER BY #{@source_keys.map { |name| SQL.identifier(name) }.join(', ')} LIMIT #{BATCH_ROWS}
          SQL
          unless source_rows.empty?
            ids = if @allocate_rowid
              source_identities = source_rows.map { |row| row.first(@source_keys.length) }
              mappings = target_identity_map_for_sources(source_identities)
              source_identities.map do |source|
                mappings[CanonicalJSON.dump(ValueCodec.encode_row(source))]
              end
            elsif @synthetic_rowid
              source_rows.map { |row| [row.fetch(0)] }
            else
              key_indexes = @target_keys.map { |key| @plan.projection.keys.index(key) }
              source_rows.map do |row|
                key_indexes.map { |index| row[@source_keys.length + index] }
              end
            end
            columns = [*@target_keys, *@plan.projection.keys]
              .map { |name| SQL.identifier(name) }.join(", ")
            lookup_ids = ids.compact
            target_rows = if lookup_ids.empty?
              []
            else
              @connection.execute(<<~SQL, lookup_ids.flatten)
                SELECT #{columns} FROM #{SQL.identifier(@names.fetch(:shadow))}
                WHERE #{tuple_sql(@target_keys)} IN (#{bind_rows(lookup_ids.length, @target_keys.length)})
                ORDER BY #{@target_keys.map { |name| SQL.identifier(name) }.join(', ')}
              SQL
            end
          end
        end
        break if source_rows.empty?
        validate_batch_rows!(source_rows, ids, target_rows, cursor)
        cursor = source_rows.last.first(@source_keys.length)
        progress = @store.status(@plan.id).progress.merge(
          "validation_source_cursor" => ValueCodec.encode_row(cursor)
        )
        @telemetry.validated(source_rows.length)
        checkpoint!(:validate_source, progress:)
      end
    end

    def validate_all_target_ranges
      @telemetry.stage = :validate_target
      encoded_cursor = @store.status(@plan.id).progress["validation_target_cursor"]
      cursor = encoded_cursor && ValueCodec.decode_row(encoded_cursor)
      loop do
        target_identities = mappings = source_rows = pending = nil
        Testing.inject(:before_validate_target_batch, plan_id: @plan.id, cursor:)
        @connection.transaction(:deferred) do
          predicate = cursor.nil? ? "" :
            "WHERE #{tuple_sql(@target_keys)} > #{bind_tuple(@target_keys.length)}"
          binds = cursor.nil? ? [] : cursor
          key_list = @target_keys.map { |name| SQL.identifier(name) }.join(", ")
          target_identities = @connection.execute(<<~SQL, binds)
            SELECT #{key_list} FROM #{SQL.identifier(@names.fetch(:shadow))}
            #{predicate} ORDER BY #{key_list} LIMIT #{BATCH_ROWS}
          SQL
          unless target_identities.empty?
            mappings = source_identity_map_for_targets(target_identities)
            source_identities = mappings.values
            source_rows = if source_identities.empty?
              []
            else
              @connection.execute(<<~SQL, source_identities.flatten)
                SELECT #{@source_keys.map { |name| SQL.identifier(name) }.join(', ')}
                FROM #{SQL.identifier(@plan.table)}
                WHERE #{tuple_sql(@source_keys)} IN (#{bind_rows(source_identities.length, @source_keys.length)})
              SQL
            end
            pending = pending_identity_keys(source_identities)
          end
        end
        break if target_identities.empty?

        source_set = source_rows.to_h do |identity|
          [CanonicalJSON.dump(ValueCodec.encode_row(identity)), true]
        end
        target_identities.each do |target_identity|
          target_key = CanonicalJSON.dump(ValueCodec.encode_row(target_identity))
          source_identity = mappings[target_key]
          unless source_identity
            raise ValidationFailed.new("target row has no source correspondence",
              details: { target_identity: ValueCodec.encode_row(target_identity) })
          end
          source_key = CanonicalJSON.dump(ValueCodec.encode_row(source_identity))
          next if source_set.key?(source_key) || pending.include?(source_key)

          raise ValidationFailed.new("target contains a row absent from the source",
            details: { target_identity: ValueCodec.encode_row(target_identity),
              source_identity: ValueCodec.encode_row(source_identity) })
        end
        validate_target_foreign_keys_for!(target_identities, table: @names.fetch(:shadow))
        cursor = target_identities.last
        progress = @store.status(@plan.id).progress.merge(
          "validation_target_cursor" => ValueCodec.encode_row(cursor)
        )
        @telemetry.validated(target_identities.length)
        checkpoint!(:validate_target, progress:)
      end
    end

    def source_identity_map_for_targets(target_identities)
      return target_identities.to_h do |identity|
        [CanonicalJSON.dump(ValueCodec.encode_row(identity)), identity]
      end unless @uses_correspondence

      source_columns = @source_keys.each_index.map { |index| "source_#{index}" }
      target_columns = @target_keys.each_index.map { |index| "target_#{index}" }
      rows = @connection.execute(<<~SQL, target_identities.flatten)
        SELECT #{[*target_columns, *source_columns].map { |name| SQL.identifier(name) }.join(', ')}
        FROM #{SQL.identifier(@names.fetch(:correspondence))}
        WHERE #{tuple_sql(target_columns)} IN (#{bind_rows(target_identities.length, target_columns.length)})
      SQL
      rows.to_h do |row|
        target = row.first(@target_keys.length)
        source = row.drop(@target_keys.length)
        [CanonicalJSON.dump(ValueCodec.encode_row(target)), source]
      end
    end

    def validate_batch_rows!(source_rows, target_ids, target_rows, cursor)
      pending = pending_identity_keys(source_rows.map { |row| row.first(@source_keys.length) })
      target_map = target_rows.to_h do |row|
        key = ValueCodec.encode_row(row.first(@target_keys.length))
        [CanonicalJSON.dump(key), row.drop(@target_keys.length)]
      end
      source_rows.each_with_index do |row, index|
        source_identity = row.first(@source_keys.length)
        next if pending.include?(CanonicalJSON.dump(ValueCodec.encode_row(source_identity)))

        expected = row.drop(@source_keys.length)
        target_identity = target_ids.fetch(index)
        unless target_identity
          raise ValidationFailed.new("source row has no target correspondence",
            details: { after_identity: cursor,
              source_identity: ValueCodec.encode_row(source_identity) })
        end
        target_key = CanonicalJSON.dump(ValueCodec.encode_row(target_identity))
        actual = target_map[target_key]
        next if actual && exact_rows?([expected], [actual])

        raise ValidationFailed.new("source projection and target rows differ",
          details: { after_identity: cursor, source_identity: ValueCodec.encode_row(source_identity) })
      end
    end

    def pending_identity_keys(identities)
      return [] if identities.empty?

      binds = identities.flatten
      placeholders = bind_rows(identities.length, @dirty_keys.length)
      [@names.fetch(:dirty), @names.fetch(:work)].flat_map do |table|
        rows = @connection.execute(<<~SQL, binds)
          SELECT #{@dirty_keys.map { |name| SQL.identifier(name) }.join(', ')}
          FROM #{SQL.identifier(table)}
          WHERE #{tuple_sql(@dirty_keys)} IN (#{placeholders})
        SQL
        rows.map { |row| CanonicalJSON.dump(ValueCodec.encode_row(row)) }
      end.uniq
    end

    def exact_rows?(source_rows, target_rows)
      return false unless source_rows.length == target_rows.length

      source_rows.zip(target_rows).all? do |source, target|
        source.zip(target).all? do |source_value, target_value|
          source_value.class == target_value.class && source_value == target_value
        end
      end
    end

    def cut_over
      @telemetry.stage = :cutover
      foreign_keys = @connection.first_value("PRAGMA foreign_keys")
      legacy = @connection.first_value("PRAGMA legacy_alter_table")
      busy_timeout = @connection.busy_timeout_ms
      @connection.execute("PRAGMA foreign_keys = OFF")
      @connection.execute("PRAGMA legacy_alter_table = ON")
      @connection.busy_timeout_ms = @plan.policy.fetch("cutover_acquire_ms")
      attempts = 0
      started_at = monotonic_time
      receipt = begin
        attempts += 1
        cut_over_once
      rescue TailTooLarge => error
        elapsed_ms = ((monotonic_time - started_at) * 1_000).round
        if attempts >= @plan.policy.fetch("max_cutover_attempts") ||
            elapsed_ms >= @plan.policy.fetch("max_cutover_elapsed_ms")
          raise CutoverTimeout.new("cutover budgets exhausted while draining the final journal tail",
            details: { attempts:, elapsed_ms:, last_error: error.message }), cause: error
        end
        @telemetry.retrying(reason: "cutover_tail", attempt: attempts, error:)
        reconcile_snapshot
        validate_all_ranges
        validate_all_target_ranges
        retry
      rescue SQLite3::BusyException, CutoverTimeout => error
        elapsed_ms = ((monotonic_time - started_at) * 1_000).round
        exhausted = attempts >= @plan.policy.fetch("max_cutover_attempts") ||
          elapsed_ms >= @plan.policy.fetch("max_cutover_elapsed_ms")
        if exhausted
          raise CutoverTimeout.new("cutover budgets exhausted with preparation intact",
            details: { attempts:, elapsed_ms:, last_error: error.message }), cause: error
        end
        delay = [attempts * 0.01, 0.1].min
        @telemetry.retrying(reason: error.is_a?(SQLite3::BusyException) ? "cutover_lock" : "cutover_budget",
          attempt: attempts, error:, wait_ms: delay * 1_000)
        sleep delay
        retry
      end
      Testing.inject(:after_cutover_commit, plan_id: @plan.id)
      # The short acquisition timeout is only for the atomic swap. Cleanup is
      # ordinary low-priority work and must not inherit the cutover timeout.
      @connection.busy_timeout_ms = busy_timeout
      @connection.execute("PRAGMA legacy_alter_table = #{legacy}")
      @connection.execute("PRAGMA foreign_keys = #{foreign_keys}")
      checkpoint!(:cut_over)
      @connection.clear_schema_cache!(@plan.table)
      cleanup_transient_artifacts
      perform_cleanup if receipt.phase == "archive_released"
      receipt
    ensure
      @connection.busy_timeout_ms = busy_timeout unless busy_timeout.nil?
      @connection.execute("PRAGMA legacy_alter_table = #{legacy}") unless legacy.nil?
      @connection.execute("PRAGMA foreign_keys = #{foreign_keys}") unless foreign_keys.nil?
    end

    def cut_over_once
      @telemetry.stage = :cutover
      Testing.inject(:before_cutover_acquire, plan_id: @plan.id)
      acquisition_started = monotonic_time
      receipt = nil
      fenced_transaction(kind: :cutover) do
        halt_for_command!(@store.status(@plan.id))
        raise CaptureLost, "LiteHM artifacts changed before cutover" unless artifacts_valid?
        ensure_source_unchanged!
        acquired_ms = ((monotonic_time - acquisition_started) * 1_000).round
        if acquired_ms > @plan.policy.fetch("cutover_acquire_ms")
          raise CutoverTimeout, "writer acquisition took #{acquired_ms}ms"
        end
        hold_started = monotonic_time
        tail = reconcile_until_clean_in_transaction
        Testing.inject(:before_final_validation, plan_id: @plan.id,
          database: @connection.database, target_identities: tail.fetch(1))
        validate_reconciled_identities!(*tail)
        promised_sequence = source_sequence
        drop_capture
        user_triggers = @plan.source_manifest.fetch("objects")
          .select { |object| object.fetch("type") == "trigger" }
        source_views = @plan.source_manifest.fetch("dependent_views", [])
        target_triggers = @plan.target_manifest.fetch("objects")
          .select { |object| object.fetch("type") == "trigger" }
        target_views = @plan.target_manifest.fetch("dependent_views", [])
        user_triggers.each { |object| @connection.execute("DROP TRIGGER #{SQL.identifier(object.fetch("name"))}") }
        source_views.each { |object| @connection.execute("DROP VIEW #{SQL.identifier(object.fetch("name"))}") }
        @connection.execute(
          "ALTER TABLE #{SQL.identifier(@plan.table)} RENAME TO #{SQL.identifier(@names.fetch(:archive))}"
        )
        @connection.execute(
          "ALTER TABLE #{SQL.identifier(@names.fetch(:shadow))} RENAME TO #{SQL.identifier(@plan.table)}"
        )
        preserve_sequence(promised_sequence)
        target_views.each { |object| @connection.execute(object.fetch("sql")) }
        target_triggers.each { |object| @connection.execute(object.fetch("sql")) }
        if live_foreign_keys?
          drop_parent_guards
          foreign_key_protocol.install(archive: true)
        end
        validate_target_foreign_keys_for!(tail.fetch(1), table: @plan.table)
        persist_index_map
        drop_artifact(@names.fetch(:dirty), "table")
        drop_artifact(@names.fetch(:work), "table")
        ephemeral = @plan.policy.fetch("archive") == "ephemeral"
        receipt_phase = ephemeral ? "archive_released" : "cut_over"
        receipt = Receipt.new(
          plan_id: @plan.id, table: @plan.table, phase: receipt_phase,
          source_hash: @plan.source_hash, target_hash: @plan.target_hash,
          cutover_at: Time.now.utc.iso8601(6), capture_state: "converged",
          archive_name: (ephemeral ? nil : @names.fetch(:archive)),
          archive_policy: @plan.policy.fetch("archive")
        )
        @store.transition(@plan.id, phase: receipt_phase, receipt:,
          archive: { "name" => @names.fetch(:archive),
            "state" => (ephemeral ? "releasing" : "retained") },
          retry_action: "cleanup", desired_state: :running)
        Testing.inject(:before_cutover_commit, plan_id: @plan.id)
        hold_ms = ((monotonic_time - hold_started) * 1_000).round
        if hold_ms > @plan.policy.fetch("cutover_hold_ms")
          raise CutoverTimeout, "cutover writer hold took #{hold_ms}ms"
        end
      end
      receipt
    rescue SQLite3::ConstraintException => error
      raise DataIncompatible.new("final source state maps multiple rows to one target identity",
        details: { sqlite_error: error.message }), cause: error
    end

    def reconcile_until_clean_in_transaction
      dirty_key_list = @dirty_keys.map { |name| SQL.identifier(name) }.join(", ")
      dirty_tail = @connection.first_value(<<~SQL)
        SELECT COUNT(*) FROM (
          SELECT 1 FROM #{SQL.identifier(@names.fetch(:dirty))} LIMIT #{BATCH_ROWS + 1}
        )
      SQL
      work_tail = @connection.first_value(<<~SQL)
        SELECT COUNT(*) FROM (
          SELECT 1 FROM #{SQL.identifier(@names.fetch(:work))} LIMIT #{BATCH_ROWS + 1}
        )
      SQL
      tail_count = dirty_tail + work_tail
      if tail_count > BATCH_ROWS
        Testing.inject(:tail_deferred, plan_id: @plan.id, rows: tail_count)
        raise TailTooLarge, "final journal tail has #{tail_count} rows; bounded drain required"
      end
      fold_dirty_into_work(dirty_key_list, limit: BATCH_ROWS)
      identities = @connection.execute(
        "SELECT #{dirty_key_list} FROM #{SQL.identifier(@names.fetch(:work))} ORDER BY #{dirty_key_list}"
      )
      return [[], [], []] if identities.empty?

      previous_target_identities = target_identities_for(identities)
      source_sizes, = payload_sizes(@plan.table, @source_keys, identities,
        projection: @plan.projection.values)
      target_sizes, = payload_sizes(@names.fetch(:shadow), @target_keys, previous_target_identities)
      if source_sizes.values.sum + target_sizes.values.sum > @write_budgets[:reconcile].byte_limit
        Testing.inject(:tail_deferred, plan_id: @plan.id, rows: identities.length)
        raise TailTooLarge, "final journal payload requires bounded reconciliation"
      end
      @connection.execute(
        "DELETE FROM #{SQL.identifier(@names.fetch(:shadow))} WHERE #{tuple_sql(@target_keys)} IN (#{bind_rows(previous_target_identities.length, @target_keys.length)})",
        previous_target_identities.flatten
      ) unless previous_target_identities.empty?
      delete_correspondence(identities) if @uses_correspondence
      insert_projected_rows(identities)
      @connection.execute("DELETE FROM #{SQL.identifier(@names.fetch(:work))}")
      current_target_identities = current_target_identities_for(identities)
      [identities, current_target_identities, previous_target_identities]
    end

    def persist_index_map
      target_indexes = @plan.target_manifest.fetch("indexes").select { |index| index["sql"] }
      logical_names = target_indexes.map { |index| index.fetch("name") }
      if logical_names.empty?
        @connection.execute(
          "UPDATE litehm_index_names SET active = 0 WHERE table_name = ?", [@plan.table]
        )
      else
        placeholders = Array.new(logical_names.length, "?").join(", ")
        @connection.execute(<<~SQL, [@plan.table, *logical_names])
          UPDATE litehm_index_names SET active = 0
          WHERE table_name = ? AND logical_name NOT IN (#{placeholders})
        SQL
      end

      target_indexes.each do |index|

        physical = SQL.artifact("index_#{index.fetch("name")}", @plan.id)
        @connection.execute(<<~SQL, [@plan.table, index.fetch("name"), physical, @plan.id])
          INSERT INTO litehm_index_names(table_name, logical_name, physical_name, plan_id, active)
          VALUES (?, ?, ?, ?, 1)
          ON CONFLICT(table_name, logical_name) DO UPDATE SET
            physical_name = excluded.physical_name,
            plan_id = excluded.plan_id,
            active = 1
        SQL
      end
    end

    def source_sequence
      return unless @plan.source_manifest.fetch("table_sql").match?(/\bAUTOINCREMENT\b/i)
      return unless table_exists?("sqlite_sequence")

      @connection.first_value("SELECT seq FROM sqlite_sequence WHERE name = ?", [@plan.table])
    end

    def preserve_sequence(promised)
      return if promised.nil?
      return unless @plan.target_manifest.fetch("table_sql").match?(/\bAUTOINCREMENT\b/i)

      current = @connection.first_value("SELECT seq FROM sqlite_sequence WHERE name = ?", [@plan.table])
      promised = [promised.to_i, current.to_i].max
      if current.nil?
        @connection.execute("INSERT INTO sqlite_sequence(name, seq) VALUES (?, ?)", [@plan.table, promised])
      else
        @connection.execute("UPDATE sqlite_sequence SET seq = ? WHERE name = ?", [promised, @plan.table])
      end
    end

    def update_assignments
      @plan.projection.keys.reject { |name| @target_keys.include?(name) }.map do |name|
        quoted = SQL.identifier(name)
        "#{quoted} = excluded.#{quoted}"
      end.join(", ")
    end

    def insert_columns_sql
      columns = @plan.projection.keys.map { |name| SQL.identifier(name) }
      columns.unshift(SQL.identifier(@synthetic_rowid)) if @synthetic_rowid
      columns.join(", ")
    end

    def insert_expressions_sql
      expressions = @plan.projection.values.dup
      expressions.unshift(SQL.identifier(@source_keys.fetch(0))) if @synthetic_rowid
      expressions.join(", ")
    end

    def dirty_progress
      count = dirty_count(limit: BATCH_ROWS + 1)
      { "dirty_rows" => count, "dirty_rows_exact" => count < BATCH_ROWS + 1,
        "dirty_rows_sampled_at" => Time.now.utc.iso8601(6) }
    end

    def dirty_count(limit: nil)
      return @connection.first_value(
        "SELECT COUNT(*) FROM #{SQL.identifier(@names.fetch(:dirty))}"
      ) unless limit

      @connection.first_value(<<~SQL)
        SELECT COUNT(*) FROM (
          SELECT 1 FROM #{SQL.identifier(@names.fetch(:dirty))} LIMIT #{Integer(limit)}
        )
      SQL
    end

    def enforce_resource_budgets!
      wal_bytes = file_size("#{@connection.path}-wal")
      max_wal = @plan.policy["max_wal_bytes"]
      if max_wal && wal_bytes > max_wal
        raise WalBudgetExceeded.new("SQLite WAL exceeded the configured LiteHM budget",
          details: { wal_bytes:, max_wal_bytes: max_wal })
      end

      total_bytes = file_size(@connection.path) + wal_bytes + file_size("#{@connection.path}-shm")
      max_database = @plan.policy["max_database_bytes"]
      if max_database && total_bytes > max_database
        raise DiskBudgetExceeded.new("SQLite database artifacts exceeded the configured LiteHM budget",
          details: { total_bytes:, max_database_bytes: max_database })
      end
    end

    def file_size(path)
      File.size(path)
    rescue Errno::ENOENT
      0
    end

    def artifacts_valid?
      expected = @store.status(@plan.id).progress["artifact_hash"]
      expected && expected == artifact_hash
    rescue SQLite3::Exception
      false
    end

    def ensure_artifact_names_available!
      names = @names.values
      @plan.target_manifest.fetch("indexes").each do |index|
        names << SQL.artifact("index_#{index.fetch("name")}", @plan.id) if index["sql"]
      end
      outbound_foreign_keys.map { |foreign_key| foreign_key.fetch("table") }.uniq.each do |parent|
        names.concat(parent_guard_names(parent))
      end
      placeholders = Array.new(names.length, "?").join(", ")
      existing = @connection.execute(<<~SQL, names).map { |row| row.fetch(0) }
        SELECT name FROM sqlite_schema
        WHERE name IN (#{placeholders})
        ORDER BY name
      SQL
      return if existing.empty?

      raise OperationConflict.new("LiteHM artifact names are already owned",
        details: { plan_id: @plan.id, artifacts: existing })
    end

    def artifact_hash
      names = [@names.fetch(:shadow), @names.fetch(:dirty), @names.fetch(:work), @names.fetch(:insert_trigger),
        @names.fetch(:update_trigger), @names.fetch(:delete_trigger)]
      names << @names.fetch(:correspondence) if @uses_correspondence
      names << @names.fetch(:allocator) if @allocate_rowid
      if outbound_foreign_keys.any?
        outbound_foreign_keys.map { |foreign_key| foreign_key.fetch("table") }.uniq.each do |parent|
          names.concat(parent_guard_names(parent))
        end
      end
      placeholders = Array.new(names.length, "?").join(", ")
      # Include every physical target index through tbl_name.
      rows = @connection.execute(<<~SQL, [*names, @names.fetch(:shadow)])
        SELECT type, name, tbl_name, sql FROM sqlite_schema
        WHERE name IN (#{placeholders}) OR tbl_name = ?
        ORDER BY type, name
      SQL
      Digest::SHA256.hexdigest(CanonicalJSON.dump(rows))
    end

    def repair_artifacts!
      @telemetry.stage = :capture_repair
      status = @store.status(@plan.id)
      assert_current_lease!
      ensure_source_unchanged!
      fenced_transaction do
        ensure_source_unchanged!
        drop_capture
        create_dirty_table
        if table_exists?(@names.fetch(:shadow))
          create_parent_guards
        else
          drop_parent_guards
        end
        create_capture
        @store.transition(@plan.id, phase: :preparing,
          progress: status.progress.merge("repairing" => true), retry_action: "resume")
      end
      drain_and_drop_table(@names.fetch(:shadow), @target_keys, before_drop: -> { drop_parent_guards })
      drain_and_drop_table(@names.fetch(:work), @dirty_keys)
      drain_and_drop_table(@names.fetch(:correspondence), correspondence_source_columns)
      drain_and_drop_table(@names.fetch(:allocator), ["id"])
      fenced_transaction do
        create_shadow
        create_work_table
        create_correspondence_table
        create_allocator_table
        create_parent_guards
        @store.transition(@plan.id, phase: :preparing,
          progress: {
            "copy_cursor" => nil,
            "copy_upper_bound" => copy_upper_bound,
            "copy_lower_bound" => copy_lower_bound,
            "copied_rows" => 0,
            "dirty_rows" => 0,
            "artifact_hash" => artifact_hash,
            "capture_repairs" => status.progress.fetch("capture_repairs", 0) + 1,
            "repairing" => false
          }.merge(@store.status(@plan.id).progress.slice("telemetry")))
      end
      Testing.inject(:after_capture_repair, plan_id: @plan.id)
    end

    def with_operation_lease
      acquired_here = !@lease_epoch
      if acquired_here
        acquire_lease
        start_lease_heartbeat
      end
      yield
    rescue ExecutionHalted
      @telemetry.publish(@store.status(@plan.id), force: true)
      raise
    rescue StandardError => error
      @telemetry.failed(error)
      raise
    ensure
      if acquired_here && @lease_epoch
        stop_lease_heartbeat
        release_lease
      end
      @generated_row_sizer&.close
      @generated_row_sizer = nil
    end

    def checkpoint!(kind, progress: nil)
      @telemetry.request_snapshot! unless %i[validate_source validate_target].include?(kind)
      transaction_kind = %i[validate_source validate_target].include?(kind) ? :validation : :control
      status = fenced_transaction(kind: transaction_kind) { @store.touch(@plan.id, progress:) }
      deliver_checkpoint!(status, kind)
    end

    def deliver_checkpoint!(status, kind)
      Testing.inject(:execution_checkpoint, plan_id: @plan.id, kind:, status:)
      current = @store.status(@plan.id)
      @telemetry.publish(current, force: %i[prepared ready cut_over aborted done].include?(kind))
      @checkpoint&.call(status, kind)
      halt_for_command!(@store.status(@plan.id))
      status
    end

    def halt_for_command!(status)
      return if status.desired_state == "running" || status.desired_state == @command_state

      raise ExecutionHalted, status.desired_state
    end

    def acquire_lease
      now = wall_clock_ms
      @connection.transaction do
        row = @connection.database.get_first_row(
          "SELECT owner, epoch, expires_at_ms FROM litehm_leases WHERE lease_name = 'writer'"
        )
        if row && row[0] != @lease_owner && row[2].to_i > now
          raise LeaseConflict.new("another LiteHM runner holds the database writer lease",
            details: { owner: row[0], epoch: row[1], expires_at_ms: row[2] })
        end

        @lease_epoch = row ? row[1].to_i + 1 : 1
        @connection.execute(<<~SQL, [@lease_owner, @lease_epoch, lease_expiry_ms])
          INSERT INTO litehm_leases(lease_name, owner, epoch, expires_at_ms)
          VALUES ('writer', ?, ?, ?)
          ON CONFLICT(lease_name) DO UPDATE SET
            owner = excluded.owner,
            epoch = excluded.epoch,
            expires_at_ms = excluded.expires_at_ms
        SQL
      end
    end

    def release_lease
      owner = @lease_owner
      epoch = @lease_epoch
      @connection.transaction do
        @connection.execute(
          "DELETE FROM litehm_leases WHERE lease_name = 'writer' AND owner = ? AND epoch = ?",
          [owner, epoch]
        )
      end
    ensure
      @lease_epoch = nil
    end

    def start_lease_heartbeat
      @heartbeat_error = nil
      @heartbeat_mutex = Mutex.new
      @heartbeat_condition = ConditionVariable.new
      @heartbeat_stopped = false
      owner = @lease_owner
      epoch = @lease_epoch
      interval = [@plan.policy.fetch("lease_ttl_ms") / 3_000.0, 0.005].max
      path = @connection.path
      @heartbeat_thread = Thread.new do
        heartbeat = Connection.open(path)
        heartbeat.busy_timeout_ms = @plan.policy.fetch("busy_timeout_ms")
        loop do
          stopped = @heartbeat_mutex.synchronize do
            @heartbeat_condition.wait(@heartbeat_mutex, interval) unless @heartbeat_stopped
            @heartbeat_stopped
          end
          break if stopped

          Testing.inject(:lease_heartbeat, plan_id: @plan.id, owner:, epoch:)
          begin
            heartbeat.transaction do
              heartbeat.execute(<<~SQL, [wall_clock_ms + @plan.policy.fetch("lease_ttl_ms"), owner, epoch])
                UPDATE litehm_leases SET expires_at_ms = ?
                WHERE lease_name = 'writer' AND owner = ? AND epoch = ?
              SQL
              raise LeaseConflict, "LiteHM heartbeat was fenced by a newer lease" if heartbeat.database.changes.zero?
            end
          rescue SQLite3::BusyException
            next
          end
        end
      rescue StandardError => error
        @heartbeat_error = error
      ensure
        heartbeat&.close
      end
      @heartbeat_thread.report_on_exception = false
    end

    def stop_lease_heartbeat
      return unless @heartbeat_thread

      @heartbeat_mutex.synchronize do
        @heartbeat_stopped = true
        @heartbeat_condition.broadcast
      end
      @heartbeat_thread.join
      @heartbeat_thread = nil
    end

    def fenced_transaction(kind: :control, rows: nil)
      budget = @write_budgets[kind]
      previous_rows = budget.row_limit
      held_at = completed_at = nil
      acquisition_started = monotonic_time
      attempts = 0
      begin
        attempts += 1
        attempt_started = monotonic_time
        saved_snapshot = false
        transaction_result = @connection.transaction do
          held_at = monotonic_time
          verify_and_renew_lease!
          result = yield
          # The summary describes completed batches and can lag by one batch.
          # Never add telemetry work to the atomic cutover budget.
          if kind != :cutover && @telemetry.snapshot_due?
            @store.save_telemetry(@plan.id, @telemetry.snapshot)
            saved_snapshot = true
          end
          result
        end
        completed_at = monotonic_time
        @telemetry.saved! if saved_snapshot
        passive_checkpoint if %i[copy reconcile cleanup].include?(kind)
        transaction_result
      rescue SQLite3::BusyException => error
        @telemetry.waited((monotonic_time - attempt_started) * 1_000) unless held_at
        # An application writer owns the writer slot. Back off without discarding prepared
        # work. Never replay a block that already acquired its transaction, and
        # leave cutover's separate attempt/acquisition budgets to its caller.
        raise if held_at || kind == :cutover ||
          (monotonic_time - acquisition_started) * 1_000 >= @plan.policy.fetch("max_cutover_elapsed_ms")

        @telemetry.retrying(reason: "writer_lock", attempt: attempts, error:,
          wait_ms: budget.pause_seconds(0) * 1_000)
        Testing.inject(:writer_lock_deferred, plan_id: @plan.id, kind:)
        halt_for_command!(@store.status(@plan.id))
        sleep budget.pause_seconds(0)
        retry
      ensure
        if held_at
          elapsed_ms = ((completed_at || monotonic_time) - held_at) * 1_000
          io_elapsed_ms = (monotonic_time - held_at) * 1_000
          count = rows.respond_to?(:call) ? rows.call : rows
          budget.observe(count, elapsed_ms)
          # Validation writes only its cursor/lease metadata. Pace that write
          # proportionally without imposing the data-batch minimum per range.
          pause_seconds = budget.pause_seconds(io_elapsed_ms, floor: kind != :validation)
          @telemetry.batch(kind:, rows: count, transaction_ms: elapsed_ms,
            lock_wait_ms: (held_at - attempt_started) * 1_000, committed: !completed_at.nil?,
            previous_rows:, next_rows: budget.row_limit, pause_ms: pause_seconds * 1_000)
          Testing.inject(:writer_batch_finished, plan_id: @plan.id, kind:,
            rows: count, elapsed_ms:, next_rows: budget.row_limit)
          # Never sleep with a transaction/read snapshot open. This also gives
          # application writers a scheduling gap after rollback and retries.
          sleep pause_seconds
        end
      end
    end

    def passive_checkpoint
      # Drain our WAL contribution outside the writer transaction, before an
      # application commit becomes the one that crosses its auto-checkpoint
      # threshold. PASSIVE never waits for readers or takes a blocking writer
      # lock; a pinned reader simply leaves frames for a later attempt.
      started = monotonic_time
      result = @connection.execute("PRAGMA wal_checkpoint(PASSIVE)").first
      @telemetry.checkpoint(result:, elapsed_ms: (monotonic_time - started) * 1_000)
      Testing.inject(:after_passive_checkpoint, plan_id: @plan.id, result:)
    rescue SQLite3::BusyException, SQLite3::LockedException
      # Another connection can own checkpointing. It is optional maintenance,
      # never a reason to replay or fail an already committed data batch.
      @telemetry.checkpoint(result: nil, elapsed_ms: (monotonic_time - started) * 1_000)
    end

    def verify_and_renew_lease!
      assert_current_lease!
      @connection.execute(
        "UPDATE litehm_leases SET expires_at_ms = ? WHERE lease_name = 'writer' AND owner = ? AND epoch = ?",
        [lease_expiry_ms, @lease_owner, @lease_epoch]
      )
    end

    def assert_current_lease!
      raise @heartbeat_error if @heartbeat_error

      row = @connection.database.get_first_row(
        "SELECT owner, epoch FROM litehm_leases WHERE lease_name = 'writer'"
      )
      unless row && row[0] == @lease_owner && row[1].to_i == @lease_epoch
        raise LeaseConflict.new("LiteHM runner was fenced by a newer lease",
          details: { owner: @lease_owner, epoch: @lease_epoch,
            current_owner: row&.fetch(0, nil), current_epoch: row&.fetch(1, nil) })
      end
    end

    def lease_expiry_ms
      wall_clock_ms + @plan.policy.fetch("lease_ttl_ms")
    end

    def wall_clock_ms
      (Time.now.to_r * 1_000).to_i
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def tuple_sql(columns)
      quoted = columns.map { |name| SQL.identifier(name) }
      columns.length == 1 ? quoted.first : "(#{quoted.join(', ')})"
    end

    def bind_tuple(size)
      size == 1 ? "?" : "(#{Array.new(size, '?').join(', ')})"
    end

    def bind_rows(row_count, width)
      Array.new(row_count, bind_tuple(width)).join(", ")
    end

    def drop_capture
      %i[insert_trigger update_trigger delete_trigger].each do |key|
        @connection.execute("DROP TRIGGER IF EXISTS #{SQL.identifier(@names.fetch(key))}")
      end
    end

    def drop_artifact(name, type)
      @connection.execute("DROP #{type.upcase} IF EXISTS #{SQL.identifier(name)}")
    end

    def table_exists?(name)
      @connection.first_value(
        "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = ?", [name]
      ).positive?
    end

    def trigger_exists?(name)
      @connection.first_value(
        "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'trigger' AND name = ?", [name]
      ).positive?
    end

    def rewrite_table_name(sql, name)
      pattern = /\ACREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"(?:[^"]|"")*"|`[^`]*`|\[[^\]]*\]|[^\s(]+)/i
      replacement = "CREATE TABLE #{SQL.identifier(name)}"
      rewritten = sql.sub(pattern, replacement)
      raise InvalidPlan, "cannot render target table SQL" if rewritten == sql

      rewritten
    end

  end
end
