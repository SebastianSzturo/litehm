# frozen_string_literal: true

module LiteHM
  class Receipt
    ATTRIBUTES = %i[
      plan_id table phase source_hash target_hash cutover_at capture_state
      archive_name archive_policy
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(**attributes)
      ATTRIBUTES.each { |key| instance_variable_set("@#{key}", attributes[key]) }
      freeze
    end

    def cut_over?
      %w[cut_over archive_released done].include?(phase.to_s)
    end

    def to_h
      ATTRIBUTES.to_h { |attribute| [attribute, public_send(attribute)] }
    end
  end
end
