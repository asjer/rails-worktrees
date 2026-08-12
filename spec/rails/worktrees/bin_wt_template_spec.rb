# rubocop:disable RSpec/DescribeClass
require 'spec_helper'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'generated bin/wt template' do
  let(:tmpdir) { Dir.mktmpdir('rails-worktrees-bin-wt-template-spec') }

  before do
    FileUtils.mkdir_p(app_root)
    install_template
    install_fake_ruby
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def app_root = File.join(tmpdir, 'app')
  def home = File.join(tmpdir, 'home')
  def local_bin = File.join(home, '.local', 'bin')
  def log_path = File.join(tmpdir, 'bootstrap.log')
  def wt_path = File.join(app_root, 'bin', 'wt')
  def real_app_root = File.realpath(app_root)
  def fallback_gem_home = File.join(tmpdir, 'fallback-gems')
  def current_lib_path = File.expand_path('../../../lib', __dir__)

  def install_template
    FileUtils.mkdir_p(File.dirname(wt_path))
    File.write(wt_path, File.read(template_path, encoding: 'UTF-8'))
    FileUtils.chmod(0o755, wt_path)
    File.write(File.join(app_root, 'Gemfile'), "source 'https://rubygems.org'\n")
  end

  def template_path
    File.expand_path('../../../lib/generators/rails/worktrees/templates/bin/wt', __dir__)
  end

  def install_fake_tool(name, content)
    FileUtils.mkdir_p(local_bin)
    path = File.join(local_bin, name)
    File.write(path, content)
    FileUtils.chmod(0o755, path)
    path
  end

  def install_fake_ruby
    install_fake_tool('ruby', <<~'BASH')
      #!/usr/bin/env bash
      {
        echo ruby
        printf 'ruby_args=%s\n' "$*"
        printf 'BUNDLE_GEMFILE=%s\n' "${BUNDLE_GEMFILE:-}"
        printf 'LANG=%s\n' "${LANG:-}"
        printf 'LC_ALL=%s\n' "${LC_ALL:-}"
      } >> "$WT_LOG"
      exit 0
    BASH
  end

  def install_real_ruby_shim
    install_fake_tool('ruby', <<~BASH)
      #!/usr/bin/env bash
      exec "#{RbConfig.ruby}" "$@"
    BASH
  end

  def install_fallback_rails_worktrees_gem
    version = Rails::Worktrees::VERSION
    gem_root = File.join(fallback_gem_home, 'gems', "rails-worktrees-#{version}")
    FileUtils.mkdir_p(File.join(gem_root, 'exe'))
    FileUtils.mkdir_p(File.join(fallback_gem_home, 'specifications'))
    File.write(File.join(gem_root, 'exe', 'wt'), <<~RUBY)
      #!/usr/bin/env ruby
      $LOAD_PATH.unshift(#{current_lib_path.inspect})
      require 'rails/worktrees'
      exit(Rails::Worktrees::CLI.new.start)
    RUBY
    FileUtils.chmod(0o755, File.join(gem_root, 'exe', 'wt'))

    spec = Gem::Specification.new do |gem_spec|
      gem_spec.name = 'rails-worktrees'
      gem_spec.version = version
      gem_spec.summary = 'Test rails-worktrees fallback executable'
      gem_spec.authors = ['RSpec']
      gem_spec.files = ['exe/wt']
      gem_spec.bindir = 'exe'
      gem_spec.executables = ['wt']
    end

    File.write(File.join(fallback_gem_home, 'specifications', "rails-worktrees-#{version}.gemspec"), spec.to_ruby)
  end

  def initialize_git_app
    FileUtils.mkdir_p(File.join(app_root, 'bin'))
    File.write(File.join(app_root, 'bin', 'rails'), "#!/usr/bin/env ruby\n")
    FileUtils.chmod(0o755, File.join(app_root, 'bin', 'rails'))

    stdout, stderr, status = Open3.capture3('git', 'init', chdir: app_root)
    expect(status).to be_success, stdout + stderr
  end

  def install_bootstrap_fallback_test_app
    install_real_ruby_shim
    install_fallback_rails_worktrees_gem
    initialize_git_app
    File.write(File.join(app_root, 'Gemfile'), <<~RUBY)
      source 'https://rubygems.org'
      gem 'rails_worktrees_missing_bootstrap_test_gem', '0.0.1'
    RUBY
  end

  def install_fake_mise
    install_fake_tool('mise', <<~'BASH')
      #!/usr/bin/env bash
      case "$1" in
        trust)
          printf 'mise_trust=%s\n' "$2" >> "$WT_LOG"
          exit 0
          ;;
        exec)
          echo mise_exec >> "$WT_LOG"
          shift
          [ "${1:-}" = "--" ] && shift
          exec "$@"
          ;;
        *)
          printf 'mise_unexpected=%s\n' "$*" >> "$WT_LOG"
          exit 64
          ;;
      esac
    BASH
  end

  def run_wt(extra_env = {}, command_args = %w[setup --dry-run])
    env = {
      'HOME' => home,
      'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin',
      'WT_LOG' => log_path,
      'LANG' => 'C',
      'LC_ALL' => 'C'
    }.merge(extra_env)

    Open3.capture3(env, wt_path, *command_args, chdir: app_root, unsetenv_others: true)
  end

  def hide_mise_bash_env
    path = File.join(tmpdir, 'hide-mise.bash')
    File.write(path, <<~BASH)
      command() {
        if [ "${1:-}" = "-v" ] && [ "${2:-}" = "mise" ]; then
          return 1
        fi
        builtin command "$@"
      }
    BASH
    path
  end

  def log_lines
    File.readlines(log_path, chomp: true)
  end

  def log_value(name)
    log_lines.grep(/\A#{Regexp.escape(name)}=/).first&.delete_prefix("#{name}=")
  end

  it 'trusts and re-execs through mise before the Ruby loader under a sparse PATH' do
    File.write(File.join(app_root, 'mise.toml'), "[tools]\nruby = '3.4.8'\n")
    install_fake_mise

    _stdout, stderr, status = run_wt

    expect(status).to be_success, stderr
    lines = log_lines
    expect(lines).to include("mise_trust=#{File.join(real_app_root, 'mise.toml')}")
    expect(lines).to include('mise_exec')
    expect(lines).to include('ruby')
    expect(lines.index('mise_exec')).to be < lines.index('ruby')
    expect(lines).to include("BUNDLE_GEMFILE=#{File.join(real_app_root, 'Gemfile')}")
    expect(lines.grep(/ruby_args=/).first).to include('/dev/fd/3 setup --dry-run')
    expect(lines.grep(/LANG=/).first).to match(/UTF-?8/i)
    expect(lines.grep(/LC_ALL=/).first).to match(/UTF-?8/i)
  end

  it 'uses the bootstrap sentinel to avoid recursively invoking mise' do
    File.write(File.join(app_root, 'mise.toml'), "[tools]\nruby = '3.4.8'\n")
    install_fake_mise

    _stdout, stderr, status = run_wt('RAILS_WORKTREES_BOOTSTRAPPED' => '1')

    expect(status).to be_success, stderr
    expect(log_lines).to include('ruby')
    expect(log_lines.grep(/\Amise_/)).to be_empty
  end

  it 're-execs through mise without a project-local config' do
    install_fake_mise

    _stdout, stderr, status = run_wt

    expect(status).to be_success, stderr
    lines = log_lines
    expect(lines).to include('mise_exec')
    expect(lines).to include('ruby')
    expect(lines.grep(/\Amise_trust=/)).to be_empty
    expect(lines.index('mise_exec')).to be < lines.index('ruby')
  end

  it 'falls back to the Ruby loader when mise is unavailable' do
    File.write(File.join(app_root, 'mise.toml'), "[tools]\nruby = '3.4.8'\n")

    _stdout, stderr, status = run_wt('BASH_ENV' => hide_mise_bash_env)

    expect(status).to be_success, stderr
    expect(log_lines).to include('ruby')
    expect(log_lines.grep(/\Amise_/)).to be_empty
  end

  it 'runs setup dry-run through the fallback executable when the app bundle is incomplete' do
    install_bootstrap_fallback_test_app

    stdout, stderr, status = run_wt(
      { 'GEM_HOME' => fallback_gem_home, 'GEM_PATH' => fallback_gem_home },
      %w[setup --dry-run]
    )

    expect(status).to be_success, stderr
    expect(stderr).to include('app bundle is incomplete')
    expect(stderr).to include('falling back to the globally installed wt executable')
    expect(stdout).to include('Dry run: previewing worktree changes without applying them')
    expect(stdout).to include('Would run: bundle install')
    expect(stdout).to include('Dry run complete')
  end

  it 'prints a clear incomplete-bundle error for non-bootstrap commands' do
    install_bootstrap_fallback_test_app

    _stdout, stderr, status = run_wt(
      { 'GEM_HOME' => fallback_gem_home, 'GEM_PATH' => fallback_gem_home },
      %w[remove old-worktree]
    )

    expect(status).not_to be_success
    expect(stderr).to include('cannot start wt because the app bundle is incomplete')
    expect(stderr).to include('Run `bundle install` or `bin/wt setup`')
    expect(stderr).not_to include('falling back to the globally installed wt executable')
  end

  it 'does not export LC_ALL when it was unset while fixing LANG' do
    _stdout, stderr, status = run_wt('LC_ALL' => nil)

    expect(status).to be_success, stderr
    expect(log_lines.grep(/\ALANG=/).first).to match(/UTF-?8/i)
    expect(log_lines).to include('LC_ALL=')
  end

  it 'normalizes bare locale names before Ruby/Bundler' do
    _stdout, stderr, status = run_wt('LANG' => 'en_US', 'LC_ALL' => nil)

    expect(status).to be_success, stderr
    expect(log_value('LANG')).to match(/UTF-?8/i)
    expect(log_value('LANG')).not_to eq('en_US')
  end

  it 'normalizes ISO-8859 locale values before Ruby/Bundler' do
    _stdout, stderr, status = run_wt('LANG' => 'nl_NL.ISO8859-15', 'LC_ALL' => 'en_US.ISO-8859-1')

    expect(status).to be_success, stderr
    expect(log_value('LANG')).to match(/UTF-?8/i)
    expect(log_value('LC_ALL')).to match(/UTF-?8/i)
  end

  it 'preserves UTF-8 locale markers and modifiers' do
    _stdout, stderr, status = run_wt('LANG' => 'en_US.UTF-8@foo', 'LC_ALL' => 'C.UTF-8')

    expect(status).to be_success, stderr
    expect(log_value('LANG')).to eq('en_US.UTF-8@foo')
    expect(log_value('LC_ALL')).to eq('C.UTF-8')
  end

  it 'preserves UTF8 locale markers without hyphens' do
    _stdout, stderr, status = run_wt('LANG' => 'en_US.UTF8', 'LC_ALL' => nil)

    expect(status).to be_success, stderr
    expect(log_value('LANG')).to eq('en_US.UTF8')
    expect(log_value('LC_ALL')).to eq('')
  end

  it 'runs doctor with C locale variables' do
    _stdout, stderr, status = run_wt({}, %w[doctor])

    expect(status).to be_success, stderr
    expect(log_lines.grep(/\Aruby_args=/).first).to include(' doctor')
    expect(log_value('LANG')).to match(/UTF-?8/i)
    expect(log_value('LC_ALL')).to match(/UTF-?8/i)
  end
end
# rubocop:enable RSpec/DescribeClass
