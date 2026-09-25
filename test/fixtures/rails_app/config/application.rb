# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_record/railtie"
require "litehm"

module LiteHMRailsFixture
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(File::NULL)
    config.secret_key_base = "litehm-fixture-secret-key-base"
    config.active_support.deprecation = :stderr
  end
end
