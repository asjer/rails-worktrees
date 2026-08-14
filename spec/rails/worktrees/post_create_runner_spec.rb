require 'spec_helper'
require 'open3'
require 'fileutils'
require 'stringio'
require 'tmpdir'

RSpec.describe Rails::Worktrees::PostCreateRunner do
  let(:tmpdir) { Dir.mktmpdir('post-create-runner-spec') }
  let(:io) { { stdout: StringIO.new, stderr: StringIO.new } }
  let(:configuration) { build_configuration }
  let(:mise_environment) do
    default_result = Rails::Worktrees::MiseEnvironment::Result.new(env: {}, messages: [])

    Object.new.tap do |environment|
      environment.define_singleton_method(:call) { default_result }
    end
  end

  before do
    allow(Rails::Worktrees::MiseEnvironment).to receive(:new).and_return(mise_environment)
  end

  around do |example|
    FileUtils.mkdir_p(target_dir)
    FileUtils.mkdir_p(peer_dir)
    example.run
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  def build_configuration
    Rails::Worktrees::Configuration.new.tap do |c|
      c.run_bundle_install = false
      c.run_yarn_install = false
      c.run_db_prepare = false
      c.run_test_db_prepare = false
      c.run_test_assets_precompile = false
      c.link_credential_keys = false
      c.link_test_credential_key = false
      c.link_production_credential_key = false
    end
  end

  def target_dir = File.join(tmpdir, 'target')

  def peer_dir = File.join(tmpdir, 'peer')

  def build_runner(bootstrapped_env: {})
    described_class.new(
      target_dir: target_dir,
      peer_roots: [peer_dir],
      configuration: configuration,
      bootstrapped_env: bootstrapped_env,
      io: io
    )
  end

  def out = io[:stdout].string

  def err = io[:stderr].string

  def runner_env
    ENV.to_h.slice('PATH', 'HOME', 'LANG', 'TERM', 'SHELL',
                   'BUNDLE_GEMFILE', 'BUNDLE_PATH', 'GEM_HOME', 'GEM_PATH',
                   'RUBY_VERSION', 'RAILS_ENV', 'NODE_ENV',
                   'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME',
                   'DEV_PORT', 'WORKTREE_DATABASE_SUFFIX').merge(target_mise_scope_env)
  end

  def target_mise_scope_env
    {
      'MISE_CEILING_PATHS' => File.dirname(target_dir),
      'MISE_TRUSTED_CONFIG_PATHS' => target_dir
    }
  end

  def popen_result(output: '', exit_status: 0)
    status = instance_double(Process::Status, exitstatus: exit_status)
    wait_thread = instance_double(Thread, value: status)
    [StringIO.new(output), wait_thread]
  end

  def stub_popen2e_sequence(*results)
    commands = []

    allow(Open3).to receive(:popen2e) do |env, *command, chdir:, &block|
      commands << { env: env, command: command, chdir: chdir }
      output, wait_thread = results.fetch(commands.length - 1)
      block.call(nil, output, wait_thread)
    end

    commands
  end

  def expected_db_and_asset_commands
    [
      { env: runner_env.merge('RAILS_ENV' => 'development'), command: %w[bin/rails db:prepare], chdir: target_dir },
      { env: runner_env.merge('RAILS_ENV' => 'test'), command: %w[bin/rails db:prepare], chdir: target_dir },
      { env: runner_env.merge('RAILS_ENV' => 'test'), command: %w[bin/rails assets:precompile], chdir: target_dir },
      { env: runner_env, command: %w[bin/rails assets:clobber], chdir: target_dir }
    ]
  end

  def configure_bundle_install!
    configuration.run_bundle_install = true
    File.write(File.join(target_dir, 'Gemfile'), "# frozen_string_literal: true\nsource 'https://rubygems.org'\n")
  end

  def expect_single_command(commands, env:, command:)
    expect(commands).to eq([{ env: env, command: command, chdir: target_dir }])
  end

  describe '#call' do
    context 'when post_create_command is false' do
      it 'returns 0 and runs nothing' do
        configuration.post_create_command = false
        configuration.run_bundle_install = true
        allow(Open3).to receive(:popen2e)

        expect(build_runner.call).to eq(0)
        expect(out).to eq('')
        expect(Open3).not_to have_received(:popen2e)
      end
    end

    context 'with a custom post_create_command' do
      before do
        configuration.post_create_command = 'echo "hello from custom"'
      end

      it 'runs the custom command and returns 0' do
        commands = stub_popen2e_sequence(popen_result(output: "hello from custom\n"))

        result = build_runner.call

        expect(result).to eq(0)
        expect(commands).to eq([{ env: runner_env, command: ['echo "hello from custom"'], chdir: target_dir }])
        expect(out).to include('hello from custom')
      end

      it 'passes the bootstrapped env to the custom command' do
        env_values = { 'DEV_PORT' => '3555', 'WORKTREE_DATABASE_SUFFIX' => '_feature_one' }
        commands = stub_popen2e_sequence(popen_result(output: "hello from custom\n"))

        build_runner(bootstrapped_env: env_values).call

        expect_single_command(
          commands,
          env: runner_env.merge(env_values),
          command: ['echo "hello from custom"']
        )
      end

      it 'returns non-zero when the custom command cannot start' do
        configuration.post_create_command = 'missing-command'
        allow(Open3).to receive(:popen2e).and_raise(Errno::ENOENT, 'No such file or directory')

        result = build_runner.call

        expect(result).to eq(1)
        expect(err).to include('Command failed to start: missing-command')
      end

      it 'returns non-zero when the custom command fails' do
        configuration.post_create_command = 'false'
        stub_popen2e_sequence(popen_result(exit_status: 1))

        result = build_runner.call

        expect(result).to eq(1)
        expect(err).to include('Command failed')
      end

      it 'preserves the caller RAILS_ENV for custom commands' do
        original = ENV.fetch('RAILS_ENV', nil)
        ENV['RAILS_ENV'] = 'production'
        commands = stub_popen2e_sequence(popen_result)

        build_runner.call

        expect(commands.first[:env]['RAILS_ENV']).to eq('production')
      ensure
        ENV['RAILS_ENV'] = original
      end

      it 'derives the mise trust scope from the target directory for custom commands' do
        original_ceiling = ENV.fetch('MISE_CEILING_PATHS', nil)
        original_trusted = ENV.fetch('MISE_TRUSTED_CONFIG_PATHS', nil)
        ENV['MISE_CEILING_PATHS'] = File.join(tmpdir, 'source-parent')
        ENV['MISE_TRUSTED_CONFIG_PATHS'] = File.join(tmpdir, 'source')
        commands = stub_popen2e_sequence(popen_result)

        build_runner.call

        expect(commands.first[:env]).to include(target_mise_scope_env)
      ensure
        ENV['MISE_CEILING_PATHS'] = original_ceiling
        ENV['MISE_TRUSTED_CONFIG_PATHS'] = original_trusted
      end

      it 'clears inherited Git selectors when deriving the target mise scope' do
        allow(Open3).to receive(:capture3).and_call_original
        stub_popen2e_sequence(popen_result)

        build_runner.call

        expect(Open3).to have_received(:capture3).with(
          hash_including('GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_COMMON_DIR' => nil),
          'git', '-C', target_dir, 'rev-parse', '--show-toplevel'
        )
      end
    end

    context 'with a custom post_create_command in dry run' do
      it 'does not run the command' do
        configuration.post_create_command = 'echo "hello from custom"'
        allow(Open3).to receive(:popen2e)

        result = build_runner.call(dry_run: true)

        expect(result).to eq(0)
        expect(out).to include('Would run: echo')
        expect(Open3).not_to have_received(:popen2e)
      end
    end

    context 'with built-in steps' do
      before do
        configure_bundle_install!
      end

      it 'runs bundle install in the target directory' do
        commands = stub_popen2e_sequence(popen_result)

        result = build_runner.call

        expect(result).to eq(0)
        expect_single_command(commands, env: runner_env, command: %w[bundle install])
        expect(out).to include('Installing gems')
      end

      it 'passes the bootstrapped env to built-in commands' do
        env_values = { 'DEV_PORT' => '3555', 'WORKTREE_DATABASE_SUFFIX' => '_feature_one' }
        commands = stub_popen2e_sequence(popen_result)

        build_runner(bootstrapped_env: env_values).call

        expect_single_command(commands, env: runner_env.merge(env_values), command: %w[bundle install])
      end

      it 'aborts remaining steps when a step fails' do
        configuration.run_db_prepare = true
        commands = stub_popen2e_sequence(popen_result(exit_status: 1))

        result = build_runner.call

        expect(result).to eq(1)
        expect(commands).to eq([{ env: runner_env, command: %w[bundle install], chdir: target_dir }])
      end
    end

    context 'with mise toolchain activation' do
      before do
        configure_bundle_install!
      end

      it 'passes the bootstrapped env into mise environment resolution' do
        env_values = { 'DEV_PORT' => '3555', 'WORKTREE_DATABASE_SUFFIX' => '_feature_one' }

        build_runner(bootstrapped_env: env_values).call

        expect(Rails::Worktrees::MiseEnvironment).to have_received(:new).with(
          target_dir: target_dir,
          env: runner_env.merge(env_values)
        )
      end

      it 'replaces source worktree mise scope with target worktree scope' do
        File.write(File.join(tmpdir, 'mise.toml'), "[tools]\nruby = '3.4.8'\n")
        source_scope = {
          'MISE_CEILING_PATHS' => File.join(tmpdir, 'source-parent'),
          'MISE_TRUSTED_CONFIG_PATHS' => File.join(tmpdir, 'source')
        }

        build_runner(bootstrapped_env: source_scope).call

        expect(Rails::Worktrees::MiseEnvironment).to have_received(:new).with(
          target_dir: target_dir,
          env: runner_env
        )
      end

      it 'merges mise env into setup subprocesses' do
        allow(mise_environment).to receive(:call).and_return(
          Rails::Worktrees::MiseEnvironment::Result.new(
            env: { 'MISE_ACTIVE' => '1' },
            messages: ['🔐 Trusting mise config...', '🧰 Activating mise toolchain...']
          )
        )
        commands = stub_popen2e_sequence(popen_result)

        build_runner.call

        expect_single_command(commands, env: runner_env.merge('MISE_ACTIVE' => '1'), command: %w[bundle install])
        expect(out).to include('Trusting mise config')
        expect(out).to include('Activating mise toolchain')
      end

      it 'returns a clear error when mise activation fails' do
        allow(mise_environment).to receive(:call).and_raise(Rails::Worktrees::Error, 'mise trust failed: nope')
        allow(Open3).to receive(:popen2e)

        expect(build_runner.call).to eq(1)
        expect(err).to include('mise trust failed: nope')
        expect(Open3).not_to have_received(:popen2e)
      end
    end

    context 'with a yarn step' do
      before do
        configuration.run_yarn_install = true
      end

      it 'skips yarn install when yarn.lock is absent' do
        allow(Open3).to receive(:popen2e)

        build_runner.call

        expect(Open3).not_to have_received(:popen2e)
      end

      it 'runs yarn install when yarn.lock is present' do
        File.write(File.join(target_dir, 'yarn.lock'), '')
        commands = stub_popen2e_sequence(popen_result)

        build_runner.call

        expect(commands).to eq([{ env: runner_env, command: %w[yarn install], chdir: target_dir }])
      end
    end

    context 'with credential key linking' do
      before do
        configuration.link_credential_keys = true

        peer_cred_dir = File.join(peer_dir, 'config/credentials')
        FileUtils.mkdir_p(peer_cred_dir)
        File.write(File.join(peer_cred_dir, 'development.key'), 'secret')
      end

      it 'links the development key and emits a message' do
        build_runner.call

        target_key = File.join(target_dir, 'config/credentials', 'development.key')
        expect(File.symlink?(target_key)).to be(true)
        expect(out).to include('Linked development.key')
      end
    end

    context 'with built-in steps in dry run' do
      before do
        configuration.run_bundle_install = true
        configuration.run_db_prepare = true
        configuration.run_test_db_prepare = true
        configuration.run_test_assets_precompile = true
      end

      it 'prints would-run lines without executing' do
        allow(Open3).to receive(:popen2e)

        result = build_runner.call(dry_run: true)

        expect(result).to eq(0)
        expect(out).to include('Would run: bundle install')
        expect(out).to include('Would run: RAILS_ENV=development bin/rails db:prepare')
        expect(out).to include('Would run: RAILS_ENV=test bin/rails db:prepare')
        expect(out).to include('Would run: RAILS_ENV=test bin/rails assets:precompile')
        expect(out).to include('Would run: bin/rails assets:clobber')
        expect(Open3).not_to have_received(:popen2e)
      end
    end

    context 'with db and asset steps' do
      before do
        configuration.run_db_prepare = true
        configuration.run_test_db_prepare = true
        configuration.run_test_assets_precompile = true
      end

      it 'runs all three steps in order and emits headers' do
        commands = stub_popen2e_sequence(
          popen_result,
          popen_result,
          popen_result,
          popen_result
        )

        build_runner.call

        expect(commands).to eq(expected_db_and_asset_commands)
        expect(out).to include('Preparing development database')
        expect(out).to include('Preparing test database')
        expect(out).to include('Precompiling test assets')
        expect(out).to include('Clobbering compiled assets')
      end
    end
  end
end
