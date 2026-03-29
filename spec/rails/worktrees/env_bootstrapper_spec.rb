# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Rails::Worktrees::EnvBootstrapper do
  let(:tmpdir) { Dir.mktmpdir('rails-worktrees-env-bootstrapper-spec') }
  let(:worktrees_root) { File.join(tmpdir, 'worktrees') }
  let(:target_dir) { File.join(worktrees_root, worktree_name) }
  let(:worktree_name) { 'feature-one' }
  let(:configuration) do
    Rails::Worktrees::Configuration.new.tap do |config|
      config.dev_port_range = (4100..4103)
    end
  end

  around do |example|
    FileUtils.mkdir_p(target_dir)
    example.run
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  def bootstrapper_for(name = worktree_name)
    described_class.new(target_dir: File.join(worktrees_root, name), worktree_name: name, configuration: configuration)
  end

  def env_contents(name = worktree_name)
    File.read(File.join(worktrees_root, name, '.env'))
  end

  def env_port_for(name)
    env_contents(name)[/^DEV_PORT=(\d+)$/, 1].to_i
  end

  it 'creates a worktree-local .env with DEV_PORT and WORKTREE_DATABASE_SUFFIX' do
    result = bootstrapper_for.call

    expect(result).to be_changed
    expect(result.values['DEV_PORT']).to match(/\A\d+\z/)
    expect(result.values['WORKTREE_DATABASE_SUFFIX']).to eq('_feature_one')
    expect(env_contents).to include('DEV_PORT=')
    expect(env_contents).to include('WORKTREE_DATABASE_SUFFIX=_feature_one')
  end

  it 'previews derived values without writing .env' do
    result = bootstrapper_for.preview

    expect(result).not_to be_changed
    expect(result.values['DEV_PORT']).to match(/\A\d+\z/)
    expect(result.values['WORKTREE_DATABASE_SUFFIX']).to eq('_feature_one')
    expect(File.exist?(File.join(target_dir, '.env'))).to be(false)
  end

  it 'derives a stable DEV_PORT from the worktree name' do
    first_dir = File.join(worktrees_root, 'feature-one')
    second_dir = File.join(tmpdir, 'other-worktrees', 'feature-one')
    FileUtils.mkdir_p(second_dir)

    first = described_class.new(target_dir: first_dir, worktree_name: 'feature-one', configuration: configuration)
    second = described_class.new(target_dir: second_dir, worktree_name: 'feature-one', configuration: configuration)

    first.call
    second.call

    expect(File.read(File.join(first_dir, '.env'))[/^DEV_PORT=(\d+)$/, 1]).to eq(
      File.read(File.join(second_dir, '.env'))[/^DEV_PORT=(\d+)$/, 1]
    )
  end

  it 'preserves existing DEV_PORT and WORKTREE_DATABASE_SUFFIX values' do
    File.write(File.join(target_dir, '.env'), "DEV_PORT=4555\nWORKTREE_DATABASE_SUFFIX=_custom\n")

    result = bootstrapper_for.call

    expect(result).not_to be_changed
    expect(env_contents).to eq("DEV_PORT=4555\nWORKTREE_DATABASE_SUFFIX=_custom\n")
  end

  it 'fills only the missing key when .env already exists' do
    File.write(File.join(target_dir, '.env'), "DEV_PORT=4555\n")

    result = bootstrapper_for.call

    expect(result).to be_changed
    expect(env_contents).to eq("DEV_PORT=4555\n\nWORKTREE_DATABASE_SUFFIX=_feature_one\n")
  end

  it 'probes deterministically for the next free port when the preferred one is claimed' do
    preferred_port = bootstrapper_for.send(:candidate_ports, configuration.dev_port_range.to_a).first
    FileUtils.mkdir_p(File.join(worktrees_root, 'occupied'))
    File.write(File.join(worktrees_root, 'occupied', '.env'), "DEV_PORT=#{preferred_port}\n")

    bootstrapper_for.call

    expect(env_port_for(worktree_name)).to eq(
      bootstrapper_for.send(:candidate_ports, configuration.dev_port_range.to_a)[1]
    )
  end

  it 'normalizes the database suffix like the setup script' do
    FileUtils.mkdir_p(File.join(worktrees_root, 'A Very Loud/Name!!!'))
    bootstrapper = described_class.new(
      target_dir: File.join(worktrees_root, 'A Very Loud/Name!!!'),
      worktree_name: 'A Very Loud/Name!!!',
      configuration: configuration.tap { |config| config.worktree_database_suffix_max_length = 8 }
    )

    bootstrapper.call

    expect(File.read(File.join(worktrees_root, 'A Very Loud/Name!!!', '.env')))
      .to include('WORKTREE_DATABASE_SUFFIX=_a_very_l')
  end

  it 'skips bootstrapping when disabled' do
    configuration.bootstrap_env = false

    result = bootstrapper_for.call

    expect(result).not_to be_changed
    expect(File.exist?(File.join(target_dir, '.env'))).to be(false)
  end
end
