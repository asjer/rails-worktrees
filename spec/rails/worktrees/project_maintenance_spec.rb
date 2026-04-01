require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe Rails::Worktrees::ProjectMaintenance do
  let(:tmpdir) { Dir.mktmpdir('rails-worktrees-project-maintenance-spec') }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def write_file(relative_path, content)
    absolute_path = File.join(tmpdir, relative_path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, content)
  end

  def check(report, identifier)
    report.checks.find { |entry| entry.identifier == identifier }
  end

  def managed_wt_template
    File.read(File.expand_path('../../../lib/generators/rails/worktrees/templates/bin/wt', __dir__))
  end

  def write_drifted_files
    write_file('bin/wt', "#!/usr/bin/env ruby\nputs 'old wt'\n")
    write_file('config/initializers/rails_worktrees.rb', <<~RUBY)
      Rails::Worktrees.configure do |config|
        config.bootstrap_env = false
      end
    RUBY
    write_file('config/database.yml', <<~YAML)
      development:
        database: demo_app_development

      test:
        database: demo_app_test
    YAML
    write_file('Procfile.dev', "web: bin/rails server\n")
    write_file('config/puma.rb', "port ENV.fetch(\"PORT\", 3000)\n")
    write_file('mise.toml', "[tools]\nruby = \"3.4.8\"\n")
  end

  def write_healthy_files
    write_file('bin/wt', managed_wt_template)
    FileUtils.chmod(0o755, File.join(tmpdir, 'bin/wt'))
    write_file('config/initializers/rails_worktrees.rb', Rails::Worktrees::InitializerUpdater.default_content)
    write_file('config/database.yml', <<~YAML)
      development:
        database: demo_app_development<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>
    YAML
    write_file('Procfile.dev', "#{Rails::Worktrees::ProcfileUpdater::STANDARD_WEB_ENTRY}\n")
    write_file('config/puma.rb', "#{Rails::Worktrees::PumaConfigUpdater::STANDARD_PORT_LINE}\n")
    write_file('mise.toml', <<~TOML)
      [tools]
      ruby = "3.4.8"

      [env]
      _.file = ".env"
    TOML
  end

  it 'reports missing required managed files as fixable' do
    report = described_class.new(root: tmpdir).call

    expect(check(report, :bin_wt)).to be_fixable
    expect(check(report, :initializer)).to be_fixable
    expect(check(report, :database)).to be_warning
  end

  it 'detects supported config drift and optional files that can be updated' do
    write_drifted_files

    report = described_class.new(root: tmpdir).call

    expect(check(report, :bin_wt)).to be_fixable
    expect(check(report, :initializer)).to be_fixable
    expect(check(report, :database)).to be_fixable
    expect(check(report, :procfile)).to be_fixable
    expect(check(report, :puma)).to be_fixable
    expect(check(report, :mise)).to be_fixable
    expect(check(report, :bin_ob)).to be_nil
  end

  it 'treats already-managed files as healthy' do
    write_healthy_files

    report = described_class.new(root: tmpdir).call

    expect(report).to be_ok
    expect(report.warning_checks).to be_empty
    expect(report.fixable_checks).to be_empty
  end

  it 'flags managed scripts with matching content but missing executable permissions as fixable' do
    write_healthy_files
    FileUtils.chmod(0o644, File.join(tmpdir, 'bin/wt'))

    report = described_class.new(root: tmpdir).call
    bin_wt = check(report, :bin_wt)

    expect(bin_wt).to be_fixable
    expect(bin_wt.headline).to eq('bin/wt needs its executable bit restored.')
    expect(bin_wt.make_executable).to be(true)
    expect(bin_wt.apply_messages).to eq(['Restored executable permissions on bin/wt.'])
  end
end
