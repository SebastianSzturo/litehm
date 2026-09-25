# frozen_string_literal: true

require_relative "lib/litehm/version"

Gem::Specification.new do |spec|
  spec.name = "litehm"
  spec.version = LiteHM::VERSION
  spec.authors = ["Sebastian Szturo"]
  spec.email = ["sebastian.szturo@gmail.com"]
  spec.summary = "Online single-table schema changes for SQLite"
  spec.description = <<~DESCRIPTION
    LiteHM applies SQLite schema changes through resumable shadow copies,
    bounded writer leases, live change capture, exact validation, and an atomic
    cutover. Its Ruby interface is inspired by Shopify's Large Hadron Migrator.
  DESCRIPTION
  spec.license = "BSD-3-Clause"
  spec.homepage = "https://github.com/SebastianSzturo/litehm"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "#{spec.homepage}#readme",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir.chdir(__dir__) do
    Dir["app/**/*", "config/**/*", "lib/**/*", "docs/**/*.md", "CHANGELOG.md", "LICENSE", "README.md"]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "sqlite3", ">= 2.9.6", "< 3"
  spec.add_dependency "rails", ">= 8.1", "< 9"
end
