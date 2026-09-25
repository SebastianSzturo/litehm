# frozen_string_literal: true

require_relative "../test_helper"

class UniqueSwapTest < Minitest::Test
  def test_n_row_unique_rotation_crosses_reconciliation_batch_boundary
    Dir.mktmpdir("litehm-swap") do |directory|
      path = File.join(directory, "swap.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE seats(id INTEGER PRIMARY KEY, position INTEGER NOT NULL);
      SQL
      database.transaction do
        300.times { |index| database.execute("INSERT INTO seats VALUES (?, ?)", [index + 1, index]) }
      end
      database.close

      plan = LiteHM.plan(:seats, id: "unique-rotation", connection: path) do |table|
        table.add_index :position, unique: true, name: :unique_seat_position
      end
      assert LiteHM.run(plan, through: :ready).ready?

      database = SQLite3::Database.new(path)
      database.execute("UPDATE seats SET position = (position + 1) % 300")
      database.close
      receipt = LiteHM.run(plan)

      assert receipt.cut_over?
      database = SQLite3::Database.new(path)
      assert_equal 300, database.get_first_value("SELECT COUNT(DISTINCT position) FROM seats")
      assert_equal 1, database.get_first_value("SELECT position FROM seats WHERE id = 1")
      assert_equal 0, database.get_first_value("SELECT position FROM seats WHERE id = 300")
      assert_equal "ok", database.get_first_value("PRAGMA integrity_check")
    ensure
      database&.close
    end
  end

  def test_incompatible_new_unique_constraint_surfaces_without_mutating_source
    Dir.mktmpdir("litehm-unique-conflict") do |directory|
      path = File.join(directory, "conflict.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute_batch(<<~SQL)
        PRAGMA journal_mode = WAL;
        CREATE TABLE seats(id INTEGER PRIMARY KEY, position INTEGER NOT NULL);
        INSERT INTO seats VALUES (1, 4), (2, 4);
      SQL
      database.close
      plan = LiteHM.plan(:seats, id: "invalid-unique", connection: path) do |table|
        table.add_index :position, unique: true
      end

      error = assert_raises(LiteHM::DataIncompatible) { LiteHM.run(plan) }
      assert_match(/UNIQUE constraint failed/, error.details.fetch(:sqlite_error))
      database = SQLite3::Database.new(path)
      assert_equal [[1, 4], [2, 4]], database.execute("SELECT * FROM seats ORDER BY id")
      assert_equal "preparing", LiteHM.status(plan.id, connection: path).phase
    ensure
      database&.close
    end
  end
end
