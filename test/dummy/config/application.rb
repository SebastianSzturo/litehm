# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "active_job/railtie"
require "litehm"

module LiteHMDummy
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(File::NULL)
    config.secret_key_base = "litehm-dummy-secret-key-base-for-tests"
    config.hosts.clear
  end
end
