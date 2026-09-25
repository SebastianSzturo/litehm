# frozen_string_literal: true

require_relative "../test_helper"

class ResumeCompilerTest < Minitest::Test
  def test_explicit_id_retry_loads_stored_manifest_without_recompiling_current_schema
    with_database do |path|
      original = LiteHM.plan(:messages, id: "stored-compiler", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end
      LiteHM.run(original)

      retried = LiteHM.plan(:messages, id: "stored-compiler", connection: path) do |table|
        table.add_column :flag, :integer, null: false, default: 0
      end

      assert_equal original.to_h, retried.to_h
      assert LiteHM.run(retried).cut_over?
    end
  end
end
