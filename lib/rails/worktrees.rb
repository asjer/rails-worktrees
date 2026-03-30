# frozen_string_literal: true

require 'pathname'

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

    INSTALL_GENERATOR_COMMAND = 'bin/rails generate rails:worktrees:install'
    REQUIRED_INSTALLATION_PATHS = [
      'bin/wt',
      'config/initializers/rails_worktrees.rb'
    ].freeze

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

      def installation_complete?(root = resolve_root)
        return false unless root

        required_installation_paths(root).all?(&:exist?)
      end

      def missing_installation_message(root: resolve_root)
        root_path = normalize_root(root)

        <<~MSG

          rails-worktrees is in your bundle, but the app installer has not run yet.

          Run:
            $ #{INSTALL_GENERATOR_COMMAND}

          Missing expected files under #{root_path}:
          #{missing_installation_items_text(root_path)}

          Docs: https://github.com/asjer/rails-worktrees
        MSG
      end

      def warn_about_missing_installation(root: resolve_root, stderr: $stderr, argv: ARGV)
        return unless missing_installation_warning_needed?(root: root, argv: argv)

        stderr.puts(missing_installation_message(root: root))
      end

      private

      def missing_installation_warning_needed?(root:, argv:)
        return false unless root
        return false if installation_complete?(root)
        return false if install_generator_invocation?(argv)

        true
      end

      def install_generator_invocation?(argv)
        normalized_args = Array(argv).map(&:to_s)

        normalized_args.include?('rails:worktrees:install') ||
          normalized_args.each_cons(2).any? { |left, right| left == 'generate' && right == 'rails:worktrees:install' }
      end

      def required_installation_paths(root)
        root_path = normalize_root(root)

        REQUIRED_INSTALLATION_PATHS.map { |relative_path| root_path.join(relative_path) }
      end

      def missing_installation_items_text(root)
        required_installation_paths(root).reject(&:exist?).map do |path|
          "  • #{path.relative_path_from(root)}"
        end.join("\n")
      end

      def resolve_root
        return unless defined?(Rails) && Rails.respond_to?(:root)

        Rails.root
      end

      def normalize_root(root)
        root.is_a?(Pathname) ? root : Pathname(root)
      end
    end
  end
end

require_relative 'worktrees/railtie' if defined?(Rails::Railtie)
