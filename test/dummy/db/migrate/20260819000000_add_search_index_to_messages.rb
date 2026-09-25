# frozen_string_literal: true

class AddSearchIndexToMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    LiteHM.change_table(:messages, id: "dummy-messages-search",
      connection: ActiveRecord::Base.connection,
      policy: { lease_ttl_ms: 100 }) do |table|
      table.add_column :searchable, :boolean, null: false, default: true
      table.add_index %i[searchable sent_at], name: :messages_searchable_sent_at
    end
  end

  def down
    LiteHM.revert("dummy-messages-search", connection: ActiveRecord::Base.connection)
  end
end
