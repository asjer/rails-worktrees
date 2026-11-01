require 'open3'

module Rails
  module Worktrees
    # Runs teardown in the target app, without borrowing the caller's suffix or bundle.
    class TeardownRunner
      RUBY_LOADER_KEYS = %w[RUBYOPT RUBYLIB].freeze
      SUFFIX_KEY = 'WORKTREE_DATABASE_SUFFIX'.freeze
      SCRIPT = File.expand_path('teardown_script.rb', __dir__).freeze

      def initialize(target_dir:, env:, io:, use_current_env: false)
        @target_dir = target_dir
        @env = env.to_h
        @stdout = io.fetch(:stdout)
        @use_current_env = use_current_env
      end

      def call(dry_run: false)
        env = runtime_env
        validate_environment!(env)
        argv = [rails_bin, 'runner', SCRIPT]
        argv << '--dry-run' if dry_run
        run(env, argv)
      rescue SystemCallError => e
        raise Error, "Could not start teardown: #{e.message}"
      end

      private

      def validate_environment!(env)
        if env[SUFFIX_KEY].to_s.strip.empty?
          raise Error, 'WORKTREE_DATABASE_SUFFIX must not be empty; refusing teardown.'
        end
        raise Error, "Expected #{@target_dir}/bin/rails for teardown." unless File.file?(rails_bin)
      end

      def run(env, argv)
        Open3.popen2e(env, *argv, chdir: @target_dir, unsetenv_others: true) do |stdin, output, wait|
          stdin.close
          output.each_line { |line| @stdout.print(line) }
          raise Error, 'Teardown failed; worktree and branch were kept.' unless wait.value.success?
        end
      end

      def rails_bin = File.join(@target_dir, 'bin', 'rails')

      def runtime_env
        env = @env.reject { |key, _| key.start_with?('BUNDLE_', 'GIT_') || RUBY_LOADER_KEYS.include?(key) }
        env.delete(SUFFIX_KEY) unless @use_current_env
        suffix = file_suffix
        env[SUFFIX_KEY] = suffix unless suffix.nil?
        env.merge('RAILS_ENV' => 'development', 'RACK_ENV' => 'development',
                  'BUNDLE_GEMFILE' => File.join(@target_dir, 'Gemfile'))
      end

      def file_suffix
        path = File.join(@target_dir, '.env')
        return unless File.file?(path)

        line = File.readlines(path, chomp: true).reverse.find do |entry|
          entry.match?(/\A\s*(?:export\s+)?WORKTREE_DATABASE_SUFFIX\s*=/)
        end
        return unless line

        value = line.split('=', 2).last.strip
        match = value.match(/\A(?:'([^']*)'|"([^"]*)"|([^\s#'"$`]*))\s*(?:#.*)?\z/)
        raise Error, 'Cannot safely read WORKTREE_DATABASE_SUFFIX from .env; use a literal value.' unless match

        match.captures.compact.first
      end
    end
  end
end
