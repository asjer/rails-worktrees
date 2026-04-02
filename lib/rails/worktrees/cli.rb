module Rails
  module Worktrees
    # Shell entrypoint for the wt executable.
    class CLI
      LOADER_OPTIONAL_COMMANDS = %w[doctor update -h --help -v --version].freeze
      LOADER_IGNORED_FLAGS = %w[--dry-run --force].freeze

      def initialize(
        argv: ARGV,
        io: { stdin: $stdin, stdout: $stdout, stderr: $stderr },
        env: ENV,
        cwd: Dir.pwd
      )
        @argv = argv
        @io = io
        @env = env
        @cwd = cwd
      end

      def start
        configuration = ::Rails::Worktrees.configuration
        load_project_configuration(configuration) if should_load_project_configuration?
        command_for(configuration).run
      rescue ::Rails::Worktrees::Error => e
        @io.fetch(:stderr).puts("Error: #{e.message}")
        1
      end

      private

      def load_project_configuration(configuration)
        ::Rails::Worktrees::ProjectConfigurationLoader.new(root: @cwd, configuration: configuration).call
      rescue StandardError, ScriptError => e
        raise ::Rails::Worktrees::Error, "Failed to load worktrees configuration: #{e.class}: #{e.message}"
      end

      def should_load_project_configuration?
        argv_without_flags.empty? || !loader_optional_command?(argv_without_flags.first)
      end

      def argv_without_flags
        @argv.reject { |arg| LOADER_IGNORED_FLAGS.include?(arg) }
      end

      def loader_optional_command?(command)
        LOADER_OPTIONAL_COMMANDS.include?(command)
      end

      def command_for(configuration)
        Command.new(argv: @argv, io: @io, env: @env, cwd: @cwd, configuration: configuration)
      end
    end
  end
end
