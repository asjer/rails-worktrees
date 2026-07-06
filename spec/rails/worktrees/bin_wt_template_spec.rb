# rubocop:disable RSpec/DescribeClass
require 'spec_helper'
require 'fileutils'
require 'open3'
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

  def run_wt(extra_env = {})
    env = {
      'HOME' => home,
      'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin',
      'WT_LOG' => log_path,
      'LANG' => 'C',
      'LC_ALL' => 'C'
    }.merge(extra_env)

    Open3.capture3(env, wt_path, 'setup', '--dry-run', chdir: app_root, unsetenv_others: true)
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

  it 'trusts and re-execs through mise before Ruby/Bundler under a sparse PATH' do
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
    expect(lines.grep(/ruby_args=/).first).to include('-rbundler/setup')
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

  it 'falls back to Ruby/Bundler when mise is unavailable' do
    File.write(File.join(app_root, 'mise.toml'), "[tools]\nruby = '3.4.8'\n")

    _stdout, stderr, status = run_wt('BASH_ENV' => hide_mise_bash_env)

    expect(status).to be_success, stderr
    expect(log_lines).to include('ruby')
    expect(log_lines.grep(/\Amise_/)).to be_empty
  end

  it 'does not export LC_ALL when it was unset while fixing LANG' do
    _stdout, stderr, status = run_wt('LC_ALL' => nil)

    expect(status).to be_success, stderr
    expect(log_lines.grep(/\ALANG=/).first).to match(/UTF-?8/i)
    expect(log_lines).to include('LC_ALL=')
  end
end
# rubocop:enable RSpec/DescribeClass
