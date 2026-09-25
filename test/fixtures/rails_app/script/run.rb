# frozen_string_literal: true

require "json"

ENV["RAILS_ENV"] = "test"
ENV["LITEHM_FIXTURE_DATABASE"] = File.expand_path(ARGV.fetch(0))
require_relative "../config/environment"

ActiveRecord::Schema.define do
  create_table :messages, force: true do |table|
    table.text :body, null: false
    table.integer :sent_at
  end
end

class Message < ActiveRecord::Base
end

Message.create!(body: "from rails", sent_at: 42)
migrations = File.expand_path("../db/migrate", __dir__)
pool = ActiveRecord::Base.connection_pool
context = ActiveRecord::MigrationContext.new(migrations, pool.schema_migration, pool.internal_metadata)
context.migrate
Message.reset_column_information
up = {
  columns: Message.column_names,
  row: Message.first.attributes,
  migration_versions: context.get_all_versions,
  litehm_phase: LiteHM.status("rails-fixture-delivery",
    connection: ActiveRecord::Base.connection).phase
}

context.rollback(1)
Message.reset_column_information
down = {
  columns: Message.column_names,
  row: Message.first.attributes,
  migration_versions: context.get_all_versions,
  litehm_phase: LiteHM.status("revert_rails-fixture-delivery",
    connection: ActiveRecord::Base.connection).phase
}

puts JSON.generate(
  up:,
  down:,
  integrity: ActiveRecord::Base.connection.select_value("PRAGMA integrity_check")
)
