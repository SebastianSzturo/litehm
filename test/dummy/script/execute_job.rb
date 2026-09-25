# frozen_string_literal: true

require "base64"
require "json"

ENV["RAILS_ENV"] = "test"
ENV["LITEHM_DUMMY_DATABASE"] = File.expand_path(ARGV.fetch(0))
require_relative "../config/environment"

payload = JSON.parse(Base64.strict_decode64(ARGV.fetch(1)))
ActiveJob::Base.execute(payload)
