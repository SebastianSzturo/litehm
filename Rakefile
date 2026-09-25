# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

task default: :test

desc "Run the full suite under every local compatibility Gemfile"
task :compatibility do
  Dir[File.expand_path("gemfiles/*.gemfile", __dir__)].sort.each do |gemfile|
    # Bundler 4 exports BUNDLE_LOCKFILE independently of BUNDLE_GEMFILE.
    # Inheriting it makes a matrix run rewrite the root lockfile.
    Bundler.with_unbundled_env do
      sh({ "BUNDLE_GEMFILE" => gemfile, "BUNDLE_LOCKFILE" => "#{gemfile}.lock" },
        "bundle", "exec", "rake", "test")
    end
  end
end
