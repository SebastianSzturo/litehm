# frozen_string_literal: true

require_relative "../test_helper"

class FinalValidationTest < Minitest::Test
  def teardown
    LiteHM::Testing.reset!
  end

  def test_final_dirty_frontier_is_compared_exactly_before_ready
    with_database do |path|
      writer = nil
      plan = LiteHM.plan(:messages, id: "exact-final-frontier", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      dirtied = false
      LiteHM::Testing.fault_injector = lambda do |point, context|
        if point == :before_ready_acquire && !dirtied
          dirtied = true
          writer = SQLite3::Database.new(path)
          writer.execute("UPDATE messages SET body = 'latest' WHERE id = 1")
          writer.close
        elsif point == :before_final_validation && context.fetch(:target_identities).any?
          shadow = LiteHM::SQL.artifact("shadow", plan.id)
          context.fetch(:database).execute(
            "UPDATE #{LiteHM::SQL.identifier(shadow)} SET body = 'corrupt' WHERE id = 1"
          )
        end
      end

      assert_raises(LiteHM::ValidationFailed) { LiteHM.run(plan) }
      assert_equal "preparing", LiteHM.status(plan.id, connection: path).phase

      LiteHM::Testing.reset!
      assert LiteHM.run(plan).cut_over?
      database = SQLite3::Database.new(path)
      assert_equal "latest", database.get_first_value("SELECT body FROM messages WHERE id = 1")
    ensure
      writer&.close
      database&.close
    end
  end

  def test_bounded_reverse_validation_rejects_extra_target_row
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "extra-target-row", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      assert LiteHM.run(plan, through: :ready).ready?
      shadow = LiteHM::SQL.artifact("shadow", plan.id)
      database = SQLite3::Database.new(path)
      database.execute(<<~SQL)
        INSERT INTO #{LiteHM::SQL.identifier(shadow)}(id, body, flag)
        VALUES (999, 'not-in-source', 0)
      SQL
      database.close

      error = assert_raises(LiteHM::ValidationFailed) { LiteHM.run(plan) }
      assert_match(/absent from the source/, error.message)
      database = SQLite3::Database.new(path)
      database.execute("DELETE FROM #{LiteHM::SQL.identifier(shadow)} WHERE id = 999")
      database.close
      assert LiteHM.run(plan).cut_over?
    ensure
      database&.close
    end
  end
end
