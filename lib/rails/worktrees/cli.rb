module Rails
  module Worktrees
    # Shell entrypoint for the wt executable.
    class CLI
      LOADER_OPTIONAL_COMMANDS = %w[doctor update -h --help -v --version].freeze
      # Commands that use project configuration when it loads, but must keep working when it does not.
      LOADER_BEST_EFFORT_COMMANDS = %w[doctor].freeze
      LOADER_IGNORED_FLAGS = %w[--dry-run --force --skip-setup --pi].freeze
      SETUP_SUBCOMMAND = 'setup'.freeze

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
        if should_load_project_configuration?
          load_project_configuration(configuration)
        elsif best_effort_configuration_command?
          load_project_configuration_best_effort(configuration)
        end
        command_for(configuration).run
      rescue ::Rails::Worktrees::Error => e
        @io.fetch(:stderr).puts("Error: #{e.message}")
        1
      end

      private

      def load_project_configuration(configuration)
        ::Rails::Worktrees::ProjectConfigurationLoader.new(root: configuration_root, configuration: configuration).call
      rescue StandardError, ScriptError => e
        raise ::Rails::Worktrees::Error, "Failed to load worktrees configuration: #{e.class}: #{e.message}"
      end

      # A broken initializer must not block recovery; wt doctor then reports with default settings.
      def load_project_configuration_best_effort(configuration)
        load_project_configuration(configuration)
      rescue ::Rails::Worktrees::Error
        configuration
      end

      def best_effort_configuration_command?
        LOADER_BEST_EFFORT_COMMANDS.include?(argv_without_flags.first)
      end

      def configuration_root
        return expand_setup_target_path if explicit_setup_path_target?

        @cwd
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

      def explicit_setup_path_target?
        argv_without_flags.first == SETUP_SUBCOMMAND && argv_without_flags.length == 2 &&
          path_like_setup_target?(argv_without_flags.last)
      end

      def expand_setup_target_path
        File.expand_path(argv_without_flags.last, @cwd)
      end

      def path_like_setup_target?(value)
        value.start_with?('/', '.', '~') || value.include?(File::SEPARATOR)
      end

      def command_for(configuration)
        Command.new(argv: @argv, io: @io, env: @env, cwd: @cwd, configuration: configuration)
      end
    end
  end
end
