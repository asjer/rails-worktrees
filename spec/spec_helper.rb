# frozen_string_literal: true

require 'rails/worktrees'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.define_derived_metadata do |meta|
    meta[:aggregate_failures] = true
  end

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.after do
    Rails::Worktrees.reset_configuration! if Rails::Worktrees.respond_to?(:reset_configuration!)
  end
end
