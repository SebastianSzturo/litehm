# frozen_string_literal: true

module LiteHM
  class Configuration
    attr_accessor :queue_name, :execution_mode, :base_controller_class,
      :connection, :authorization, :log_events, :stalled_after

    def initialize
      @queue_name = :litehm
      @execution_mode = :async
      @base_controller_class = "ActionController::Base"
      @connection = -> { ActiveRecord::Base.connection }
      @authorization = nil
      @log_events = true
      # Seconds without a live writer lease or a committed safe point before an
      # operation that still wants work counts as stalled (see RecoveryJob).
      @stalled_after = 15 * 60
    end

    def authorize_with(&block)
      self.authorization = block
    end
  end
end
