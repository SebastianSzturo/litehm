# frozen_string_literal: true

require_relative "../test_helper"

class ModelTraceTest < Minitest::Test
  VALUES = [nil, -7, 1.25, "text\0snow-雪", "".b, "\x00\xff".b].freeze

  def test_seeded_dml_traces_match_quiescent_projection_exactly
    12.times do |seed|
      Dir.mktmpdir("litehm-model-#{seed}") do |directory|
        path = File.join(directory, "model.sqlite3")
        create_source(path)
        plan = LiteHM.plan(:records, id: "model-#{seed}", connection: path,
          adapter: :raw) do |table|
          table.ddl <<~SQL
            DROP TABLE #{table.name};
            CREATE TABLE #{table.name}(
              id INTEGER PRIMARY KEY,
              payload,
              note TEXT,
              storage_class TEXT NOT NULL
            );
          SQL
          table.project :storage_class, "typeof(payload)"
        end
        LiteHM.run(plan, through: :ready)
        apply_trace(path, seed)
        expected = projected_rows(path)

        LiteHM.run(plan)
        database = SQLite3::Database.new(path)
        actual = database.execute(
          "SELECT id, payload, note, storage_class FROM records ORDER BY id"
        )
        assert_equal expected, actual, "seed #{seed}"
        assert_equal expected.map { |row| row[1].class }, actual.map { |row| row[1].class }, "seed #{seed} types"
        assert_equal "ok", database.get_first_value("PRAGMA integrity_check"), "seed #{seed}"
      ensure
        database&.close
      end
    end
  end

  private

  def create_source(path)
    database = SQLite3::Database.new(path)
    database.execute_batch(<<~SQL)
      PRAGMA journal_mode = WAL;
      CREATE TABLE records(id INTEGER PRIMARY KEY, payload, note TEXT);
    SQL
    [-10, -1, 1, 5, 99].each_with_index do |id, index|
      database.execute("INSERT INTO records VALUES (?, ?, ?)", [id, VALUES[index], "initial-#{index}"])
    end
  ensure
    database&.close
  end

  def apply_trace(path, seed)
    random = Random.new(seed)
    database = SQLite3::Database.new(path)
    database.busy_timeout = 10_000
    30.times do |step|
      database.transaction(:immediate) do
        case random.rand(3)
        when 0
          id = random.rand(-20..120)
          database.execute(<<~SQL, [id, VALUES.sample(random: random), "insert-#{step}"])
            INSERT INTO records(id, payload, note) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, note = excluded.note
          SQL
        when 1
          ids = database.execute("SELECT id FROM records ORDER BY id").flatten
          unless ids.empty?
            database.execute("UPDATE records SET payload = ?, note = ? WHERE id = ?",
              [VALUES.sample(random: random), "update-#{step}", ids.sample(random: random)])
          end
        when 2
          ids = database.execute("SELECT id FROM records ORDER BY id").flatten
          database.execute("DELETE FROM records WHERE id = ?", [ids.sample(random: random)]) unless ids.empty?
        end
      end
    end
  ensure
    database&.close
  end

  def projected_rows(path)
    database = SQLite3::Database.new(path)
    database.execute(<<~SQL)
      SELECT id, payload, note, typeof(payload) FROM records ORDER BY id
    SQL
  ensure
    database&.close
  end
end
