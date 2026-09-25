# frozen_string_literal: true

class AddDeliveryToMessages < ActiveRecord::Migration[ActiveRecord::VERSION::STRING.to_f]
  disable_ddl_transaction!

  def up
    LiteHM.change_table(:messages, id: "rails-fixture-delivery",
      connection: ActiveRecord::Base.connection, execution: :inline) do |table|
      table.rename_column :body, :content
      table.add_column :delivered, :boolean, null: false, default: false
      table.add_index %i[delivered sent_at], name: :messages_delivery
    end
  end

  def down
    LiteHM.revert("rails-fixture-delivery", connection: ActiveRecord::Base.connection,
      execution: :inline)
  end
end
