require 'open3'

module Rails
  module Worktrees
    # Runs post-create setup steps in a newly created worktree.
    # Steps run in order: credential linking, bundle install, yarn install,
    # db:prepare (development), db:prepare (test), assets:precompile (test), assets:clobber.
    # rubocop:disable Metrics/ClassLength
    class PostCreateRunner
      STEPS = [
        { id: :bundle, argv: %w[bundle install],
          header: '📦 Installing gems...' },
        { id: :yarn, argv: %w[yarn install],
          header: '🧶 Installing JS dependencies...' },
        { id: :db_prepare, argv: %w[bin/rails db:prepare],
          header: '🗄️  Preparing development database...', env: { 'RAILS_ENV' => 'development' } },
        { id: :test_db_prepare, argv: %w[bin/rails db:prepare],
          header: '🗄️  Preparing test database...', env: { 'RAILS_ENV' => 'test' } },
        { id: :test_assets_precompile, argv: %w[bin/rails assets:precompile],
          header: '🎨 Precompiling test assets...', env: { 'RAILS_ENV' => 'test' } },
        { id: :assets_clobber, argv: %w[bin/rails assets:clobber],
          header: '🧹 Clobbering compiled assets...' }
      ].freeze

      STEP_CONFIG = {
        bundle: :run_bundle_install,
        yarn: :run_yarn_install,
        db_prepare: :run_db_prepare,
        test_db_prepare: :run_test_db_prepare,
        test_assets_precompile: :run_test_assets_precompile,
        assets_clobber: :run_test_assets_precompile
      }.freeze

      def initialize(target_dir:, peer_roots:, configuration:, io:, bootstrapped_env: nil)
        @target_dir    = target_dir
        @peer_roots    = peer_roots
        @configuration = configuration
        @bootstrapped_env = (bootstrapped_env || {}).transform_values(&:to_s)
        @stdout        = io.fetch(:stdout)
        @stderr        = io.fetch(:stderr)
      end

      def call(dry_run: false)
        return 0 if @configuration.post_create_command == false

        @runtime_env = resolved_runtime_env(dry_run: dry_run)

        return run_custom_command(dry_run: dry_run) if custom_command?

        run_built_in_steps(dry_run: dry_run)
      rescue Error => e
        @stderr.puts("❌ #{e.message}")
        1
      end

      private

      def custom_command?
        @configuration.post_create_command.is_a?(String) && !@configuration.post_create_command.empty?
      end

      def run_custom_command(dry_run:)
        command = @configuration.post_create_command

        if dry_run
          info("Would run: #{command}")
          return 0
        end

        info("Running: #{command}")
        stream_shell_command(command)
      end

      def run_built_in_steps(dry_run:)
        result = run_credential_linking(dry_run: dry_run)
        return result unless result.zero?

        STEPS.each do |step|
          config_attr = STEP_CONFIG[step[:id]]
          next unless @configuration.public_send(config_attr)
          next if step[:id] == :yarn && !yarn_lock_present?

          result = run_step(step, dry_run: dry_run)
          return result unless result.zero?
        end

        0
      end

      def run_credential_linking(dry_run:)
        # Missing peer key files are intentionally best-effort and should not abort
        # worktree setup; the linker reports those cases in its messages while real
        # filesystem errors still raise out of `credential_key_linker.call`.
        return 0 unless credential_linking_enabled?

        info('🔑 Linking credential keys...')

        result = credential_key_linker.call(dry_run: dry_run)
        print_credential_linking_messages(result)

        0
      end

      def run_step(step, dry_run:)
        if dry_run
          info("Would run: #{display_command(step)}")
          return 0
        end

        info(step[:header])
        stream_step_command(step)
      end

      def stream_shell_command(command)
        exit_status = capture_shell_command_exit_status(command)
        report_failed_command(command, exit_status) unless exit_status.zero?
        exit_status
      end

      def stream_step_command(step)
        command = display_command(step)
        exit_status = capture_step_command_exit_status(step)
        report_failed_command(command, exit_status) unless exit_status.zero?
        exit_status
      end

      def capture_shell_command_exit_status(command)
        exit_status = nil

        Open3.popen2e(runtime_env, command, chdir: @target_dir) do |_stdin, output, wait_thread|
          output.each_line { |line| @stdout.print(line) }
          exit_status = wait_thread.value.exitstatus
        end

        exit_status
      rescue StandardError => e
        report_failed_command_start(command, e)
        1
      end

      def capture_step_command_exit_status(step)
        exit_status = nil

        Open3.popen2e(*step_command(step), chdir: @target_dir) do |_stdin, output, wait_thread|
          output.each_line { |line| @stdout.print(line) }
          exit_status = wait_thread.value.exitstatus
        end

        exit_status
      rescue StandardError => e
        report_failed_command_start(display_command(step), e)
        1
      end

      def shell_env
        # Pass through only the essentials so subprocess tools work correctly.
        ENV.to_h.slice('PATH', 'HOME', 'LANG', 'TERM', 'SHELL',
                       'BUNDLE_GEMFILE', 'BUNDLE_PATH', 'GEM_HOME', 'GEM_PATH',
                       'RUBY_VERSION', 'RAILS_ENV', 'NODE_ENV',
                       'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME',
                       'DEV_PORT', 'WORKTREE_DATABASE_SUFFIX', 'MISE_CEILING_PATHS')
      end

      attr_reader :runtime_env

      def resolved_runtime_env(dry_run:)
        env = shell_env.merge(@bootstrapped_env)
        return env if dry_run

        env.merge(toolchain_env)
      end

      def toolchain_env
        result = MiseEnvironment.new(target_dir: @target_dir, env: shell_env.merge(@bootstrapped_env)).call
        result.messages.each { |message| info(message) }
        result.env
      end

      def yarn_lock_present?
        File.exist?(File.join(@target_dir, 'yarn.lock'))
      end

      def display_command(step)
        env_prefix = step.fetch(:env, {}).map { |key, value| "#{key}=#{value}" }.join(' ')
        command = step.fetch(:argv).join(' ')
        [env_prefix, command].reject(&:empty?).join(' ')
      end

      def step_command(step)
        [runtime_env.merge(step.fetch(:env, {})), *step.fetch(:argv)]
      end

      def info(message)
        @stdout.puts("→ #{message}")
      end

      def report_failed_command(command, exit_status)
        @stderr.puts("❌ Command failed (exit #{exit_status}): #{command}")
      end

      def report_failed_command_start(command, error)
        @stderr.puts("❌ Command failed to start: #{command} (#{error.message})")
      end

      def credential_linking_enabled?
        @configuration.link_credential_keys ||
          @configuration.link_test_credential_key ||
          @configuration.link_production_credential_key
      end

      def credential_key_linker
        CredentialKeyLinker.new(
          target_dir: @target_dir,
          peer_roots: @peer_roots,
          configuration: @configuration
        )
      end

      def print_credential_linking_messages(result)
        result.messages.each { |message| info("   #{message}") }
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
