require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe Rails::Worktrees::ProjectConfigurationLoader do
  let(:tmpdir) { Dir.mktmpdir('rails-worktrees-project-configuration-loader-spec') }
  let(:configuration) { Rails::Worktrees::Configuration.new }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def write_initializer(content)
    path = File.join(tmpdir, 'config/initializers/rails_worktrees.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  it 'loads assignments from the current managed initializer format' do
    write_initializer(<<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
        config.branch_prefix = '🌿'
        config.name_sources_path = Rails.root.join('config/worktree_names').to_s
      end
    RUBY

    described_class.new(root: File.join(tmpdir, 'app/models'), configuration: configuration).call

    expect(configuration.branch_prefix).to eq('🌿')
    expect(configuration.name_sources_path).to eq(File.join(tmpdir, 'config/worktree_names'))
  end

  it 'loads assignments from the older configure-based initializer format' do
    write_initializer(<<~RUBY)
      if defined?(Rails::Worktrees)
        Rails::Worktrees.configure do |config|
          config.bootstrap_env = false
          config.dev_port_range = 4100..4199
        end
      end
    RUBY

    described_class.new(root: tmpdir, configuration: configuration).call

    expect(configuration.bootstrap_env).to be(false)
    expect(configuration.dev_port_range).to eq(4100..4199)
  end

  it 'lets legacy configure-based initializers read default configuration values' do
    write_initializer(<<~RUBY)
      if defined?(Rails::Worktrees)
        Rails::Worktrees.configure do |config|
          config.dev_port_range = config.branch_prefix == '🚂' ? (3000..3999) : (4000..4999)
        end
      end
    RUBY

    described_class.new(root: tmpdir, configuration: configuration).call

    expect(configuration.dev_port_range).to eq(3000..3999)
  end

  it 'ignores unknown keys while still applying supported ones' do
    write_initializer(<<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
        config.bootstrap_env = false
        config.rocket_mode = true
      end
    RUBY

    expect do
      described_class.new(root: tmpdir, configuration: configuration).call
    end.not_to raise_error

    expect(configuration.bootstrap_env).to be(false)
  end

  it 'serializes temporary Rails.root overrides with a mutex' do
    write_initializer(<<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
        config.branch_prefix = '🌿'
      end
    RUBY

    mutex = instance_double(Mutex)
    original_root = Rails.root if Rails.respond_to?(:root)

    stub_const("#{described_class}::TEMP_RAILS_ROOT_MUTEX", mutex)
    allow(mutex).to receive(:synchronize).and_yield

    described_class.new(root: tmpdir, configuration: configuration).send(:with_temporary_rails_root) do
      expect(Rails.root).to eq(Pathname(tmpdir))
    end

    expect(mutex).to have_received(:synchronize)
    expect(Rails.root).to eq(original_root) if original_root
  end

  it 'reports getter and setter support for the assignment recorder' do
    recorder = described_class::AssignmentRecorder.new

    expect(recorder).to respond_to(:branch_prefix)
    expect(recorder).to respond_to(:branch_prefix=)
  end

  it 'skips unsupported initializer shapes without changing configuration' do
    write_initializer("puts 'too custom'\n")

    described_class.new(root: tmpdir, configuration: configuration).call

    expect(configuration.branch_prefix).to eq('🚂')
  end
end
