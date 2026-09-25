# frozen_string_literal: true

module LiteHM
  class Error < StandardError
    attr_reader :details

    def initialize(message = nil, details: {})
      @details = details.freeze
      super(message)
    end
  end

  class InvalidPlan < Error; end
  class UnsupportedObject < Error; end
  class PlanConflict < Error; end
  class OperationConflict < Error; end
  class LeaseConflict < OperationConflict; end
  class SchemaDrift < Error; end
  class CaptureLost < Error; end
  class ReverseProjectionRequired < Error; end
  class DataIncompatible < Error; end
  class AbortUnavailable < Error; end
  class ArchiveReleased < Error; end
  class DiskBudgetExceeded < Error; end
  class WalBudgetExceeded < Error; end
  class BusyBudgetExceeded < Error; end
  class ValidationFailed < Error; end
  class CutoverTimeout < Error; end
  class VersionUnsupported < Error; end
end
