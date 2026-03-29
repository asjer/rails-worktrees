# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

require 'rubocop/rake_task'

RuboCop::RakeTask.new

namespace :smoke do
  desc 'Run the disposable Rails app smoke test'
  task :test do
    script = File.expand_path('spec/integration/smoke_test.sh', __dir__)

    Bundler.with_unbundled_env do
      success = system(script)
      abort('Smoke test failed') unless success
    end
  end
end

desc 'Run the disposable Rails app smoke test'
task smoke_test: 'smoke:test'

task default: %i[spec rubocop]
