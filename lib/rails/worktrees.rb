# frozen_string_literal: true

require_relative 'worktrees/version'
require_relative 'worktrees/configuration'
require_relative 'worktrees/env_bootstrapper'
require_relative 'worktrees/command'
require_relative 'worktrees/cli'
require_relative 'worktrees/database_config_updater'

module Rails
  # Rails-specific git worktree helpers and installer support.
  module Worktrees
    class Error < StandardError; end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
        configuration
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end

require_relative 'worktrees/railtie' if defined?(Rails::Railtie)
