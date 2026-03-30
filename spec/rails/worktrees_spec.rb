require 'fileutils'
require 'stringio'
require 'tmpdir'

RSpec.describe Rails::Worktrees do
  after do
    described_class.reset_configuration!
  end

  it 'has a version number' do
    expect(Rails::Worktrees::VERSION).not_to be_nil
  end

  it 'defines an error class' do
    expect(Rails::Worktrees::Error).to be < StandardError
  end

  it 'exposes a configuration object' do
    expect(described_class.configuration).to be_a(Rails::Worktrees::Configuration)
  end

  it 'yields configuration updates' do
    described_class.configure do |config|
      config.branch_prefix = '🌿'
    end

    expect(described_class.configuration.branch_prefix).to eq('🌿')
  end

  it 'returns the configuration object from configure' do
    returned_configuration = described_class.configure do |config|
      config.branch_prefix = '🌿'
      :ignored_block_value
    end

    expect(returned_configuration).to be(described_class.configuration)
  end

  describe 'install guidance' do
    let(:tmpdir) { Dir.mktmpdir('rails-worktrees-install-guidance-spec') }

    after do
      FileUtils.rm_rf(tmpdir)
    end

    it 'detects when the app installer has not run yet' do
      expect(described_class.installation_complete?(tmpdir)).to be(false)
    end

    it 'detects when the app installer has already created its files' do
      FileUtils.mkdir_p(File.join(tmpdir, 'bin'))
      FileUtils.mkdir_p(File.join(tmpdir, 'config/initializers'))
      File.write(File.join(tmpdir, 'bin/wt'), "#!/usr/bin/env ruby\n")
      File.write(File.join(tmpdir, 'config/initializers/rails_worktrees.rb'), "# installed\n")

      expect(described_class.installation_complete?(tmpdir)).to be(true)
    end

    it 'warns with the generator command when installation files are missing' do
      output = StringIO.new

      described_class.warn_about_missing_installation(
        root: tmpdir,
        stderr: output,
        argv: %w[server]
      )

      expect(output.string).to include('bin/rails generate worktrees:install')
      expect(output.string).to include('bin/wt')
      expect(output.string).to include('config/initializers/rails_worktrees.rb')
    end

    it 'returns a generic install message when no app root is available' do
      message = described_class.missing_installation_message(root: nil)

      expect(message).to include('bin/rails generate worktrees:install')
      expect(message).not_to include('Missing expected files under')
    end

    it 'stays quiet while the shorter installer generator name is running' do
      output = StringIO.new

      described_class.warn_about_missing_installation(
        root: tmpdir,
        stderr: output,
        argv: %w[generate worktrees:install]
      )

      expect(output.string).to eq('')
    end

    it 'stays quiet while the Rails generator alias is running' do
      output = StringIO.new

      described_class.warn_about_missing_installation(
        root: tmpdir,
        stderr: output,
        argv: %w[g worktrees:install]
      )

      expect(output.string).to eq('')
    end
  end
end
