require 'spec_helper'
require 'fileutils'
require 'stringio'
require 'tmpdir'

RSpec.describe Rails::Worktrees::CLI do
  let(:tmpdir) { Dir.mktmpdir('rails-worktrees-cli-spec') }
  let(:io) { { stdin: StringIO.new, stdout: StringIO.new, stderr: StringIO.new } }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def write_initializer(content)
    path = File.join(tmpdir, 'config/initializers/rails_worktrees.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_initializer_at(root, branch_prefix:)
    path = File.join(root, 'config/initializers/rails_worktrees.rb')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
        config.branch_prefix = '#{branch_prefix}'
      end
    RUBY
  end

  def expect_command_configuration(branch_prefix)
    fake_command = instance_spy(Rails::Worktrees::Command, run: 0)

    allow(Rails::Worktrees::Command).to receive(:new) do |**kwargs|
      expect(kwargs.fetch(:configuration).branch_prefix).to eq(branch_prefix)
      fake_command
    end
  end

  it 'loads project configuration before building a config-dependent command' do
    write_initializer(<<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
        config.branch_prefix = '🌿'
      end
    RUBY

    fake_command = instance_spy(Rails::Worktrees::Command, run: 0)

    allow(Rails::Worktrees::Command).to receive(:new) do |**kwargs|
      expect(kwargs.fetch(:configuration).branch_prefix).to eq('🌿')
      fake_command
    end

    result = described_class.new(argv: [], io: io, cwd: tmpdir).start

    expect(result).to eq(0)
    expect(Rails::Worktrees::Command).to have_received(:new)
  end

  it 'does not let a broken initializer block recovery commands' do
    write_initializer(<<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
        config.branch_prefix =
      end
    RUBY

    fake_command = instance_spy(Rails::Worktrees::Command, run: 0)
    allow(Rails::Worktrees::Command).to receive(:new).and_return(fake_command)

    result = described_class.new(argv: ['doctor'], io: io, cwd: tmpdir).start

    expect(result).to eq(0)
    expect(io.fetch(:stderr).string).to eq('')
    expect(Rails::Worktrees::Command).to have_received(:new)
  end

  it 'prints a friendly error when a config-dependent command cannot load the initializer' do
    write_initializer(<<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
        config.branch_prefix =
      end
    RUBY

    fake_command = instance_spy(Rails::Worktrees::Command, run: 0)
    allow(Rails::Worktrees::Command).to receive(:new).and_return(fake_command)

    result = described_class.new(argv: [], io: io, cwd: tmpdir).start

    expect(result).to eq(1)
    expect(io.fetch(:stderr).string).to include('Error: Failed to load worktrees configuration: SyntaxError:')
    expect(Rails::Worktrees::Command).not_to have_received(:new)
  end

  it 'loads project configuration from the explicit wt setup target path' do
    target_root = File.join(tmpdir, 'external-checkout')
    write_initializer_at(target_root, branch_prefix: '🧭')
    expect_command_configuration('🧭')

    result = described_class.new(argv: ['setup', target_root], io: io, cwd: tmpdir).start

    expect(result).to eq(0)
    expect(Rails::Worktrees::Command).to have_received(:new)
  end

  it 'keeps using the caller project configuration for wt setup <name>' do
    write_initializer(<<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
        config.branch_prefix = '🌿'
      end
    RUBY

    target_root = File.join(tmpdir, 'feature-one')
    write_initializer_at(target_root, branch_prefix: '🧭')
    expect_command_configuration('🌿')

    result = described_class.new(argv: %w[setup feature-one], io: io, cwd: tmpdir).start

    expect(result).to eq(0)
    expect(Rails::Worktrees::Command).to have_received(:new)
  end
end
