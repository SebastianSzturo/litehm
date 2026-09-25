# frozen_string_literal: true

require_relative "../test_helper"

class ArtifactOwnershipTest < Minitest::Test
  def test_complete_plan_id_is_hashed_for_artifact_names
    first = LiteHM::SQL.artifact("shadow", "20260818000000-alpha")
    second = LiteHM::SQL.artifact("shadow", "20260818000000-alpine")

    refute_equal first, second
    assert_match(/\A__litehm_shadow_[0-9a-f]{24}\z/, first)
  end

  def test_new_plan_refuses_preexisting_artifact_name
    with_database do |path|
      plan = LiteHM.plan(:messages, id: "owned-artifact", connection: path) do |table|
        table.add_column :flag, :integer
      end
      shadow = LiteHM::SQL.artifact("shadow", plan.id)
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE #{LiteHM::SQL.identifier(shadow)}(id INTEGER)")
      database.close

      error = assert_raises(LiteHM::OperationConflict) { LiteHM.run(plan) }
      assert_equal [shadow], error.details.fetch(:artifacts)
      database = SQLite3::Database.new(path)
      assert_equal %w[id body sent_at metadata],
        database.execute("PRAGMA table_xinfo(messages)").map { |row| row[1] }
    ensure
      database&.close
    end
  end
end
