# frozen_string_literal: true

LiteHM.configure do |config|
  config.execution_mode = :async
  config.queue_name = :litehm
  config.base_controller_class = "ApplicationController"
  config.connection = -> { ActiveRecord::Base.connection }
  config.authorize_with do |controller|
    controller.request.headers["HTTP_X_LITEHM_TOKEN"] == "dummy-secret"
  end
end
