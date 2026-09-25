# frozen_string_literal: true

require "rails"

ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym "LiteHM" }

module LiteHM
  class Engine < ::Rails::Engine
    isolate_namespace LiteHM

    initializer "litehm.structured_events", after: :load_config_initializers do
      Rails.event.unsubscribe(Telemetry::LogSubscriber)
      Rails.event.subscribe(Telemetry::LogSubscriber.new) { |event| event[:name].start_with?("litehm.") }
    end

    initializer "litehm.active_record_integration" do
      ActiveSupport.on_load(:active_record) { LiteHM::ActiveRecordIntegration.install! }
    end
  end
end
