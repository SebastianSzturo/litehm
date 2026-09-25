# frozen_string_literal: true

module LiteHM
  module Testing
    class << self
      attr_accessor :fault_injector

      def inject(point, context = {})
        fault_injector&.call(point, context)
      end

      def reset!
        self.fault_injector = nil
      end
    end
  end
end
