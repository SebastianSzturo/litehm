# frozen_string_literal: true

require "active_job"

module LiteHM
  # Schedule this every few minutes (e.g. Solid Queue recurring tasks) so a
  # worker that dies without a graceful stop cannot leave an operation stalled.
  class RecoveryJob < ActiveJob::Base
    queue_as { LiteHM.configuration.queue_name }

    def perform(database_path = nil)
      LiteHM.recover_stalled(connection: database_path)
    end
  end
end
