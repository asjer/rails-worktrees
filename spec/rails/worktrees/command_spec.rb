# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'stringio'
require 'tmpdir'

RSpec.describe Rails::Worktrees::Command do
  let(:tmpdir) { Dir.mktmpdir('rails-worktrees-command-spec') }
  let(:workspace_root_override) { File.join(tmpdir, 'workspaces') }

  let(:configuration) do
    Rails::Worktrees::Configuration.new.tap do |config|
      config.workspace_root = workspace_root_override
      config.used_names_file = File.join(tmpdir, 'state', 'used-names.tsv')
      config.name_sources_path = File.join(tmpdir, 'names')
      config.legacy_used_names_files = []
    end
  end

  around do |example|
    FileUtils.mkdir_p(configuration.name_sources_path)
    File.write(File.join(configuration.name_sources_path, 'cities.txt'), "daegu\n")
    bootstrap_git_repository
    example.run
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  def repo_path = File.join(tmpdir, 'app')
  def origin_path = File.join(tmpdir, 'origin.git')
  def default_workspaces_root = File.join(tmpdir, 'app.worktrees')

  def build_command(argv: [], stdin: StringIO.new, stdout: StringIO.new, stderr: StringIO.new, env: {})
    # Use only path-related variables from the host to allow tools like `git` to run
    base_env = ENV.to_h.slice('PATH', 'HOME')

    described_class.new(
      argv: argv,
      io: { stdin: stdin, stdout: stdout, stderr: stderr },
      env: base_env.merge(env),
      cwd: repo_path,
      configuration: configuration
    )
  end

  describe '#run' do
    it 'creates a new worktree for an explicit name' do
      out = StringIO.new
      expect(build_command(argv: ['feature-one'], stdout: out).run).to eq(0)

      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      env_text = File.read(File.join(target_dir, '.env'))
      dev_port = env_text[/^DEV_PORT=(\d+)$/, 1]

      expect(File.directory?(target_dir)).to be(true)
      expect(env_text).to include('WORKTREE_DATABASE_SUFFIX=_feature_one')
      expect(env_text).to match(/^DEV_PORT=\d+$/)
      expect(git_output('-C', target_dir, 'branch', '--show-current')).to eq('🚂/feature-one')
      expect(out.string).to include('Worktree ready')
      expect(out.string).to include("Port:   #{dev_port}")
      expect(out.string).to include('Suffix: _feature_one')
    end

    it 'prints derived env values without creating a worktree' do
      out = StringIO.new

      expect(build_command(argv: ['--print-env', 'feature-one'], stdout: out).run).to eq(0)

      expect(out.string).to match(/^DEV_PORT=\d+$/)
      expect(out.string).to include('WORKTREE_DATABASE_SUFFIX=_feature_one')
      expect(File.directory?(File.join(configuration.workspace_root, 'app', 'feature-one'))).to be(false)
    end

    it 'dry-runs a new worktree without creating it' do
      out = StringIO.new

      expect(build_command(argv: ['--dry-run', 'feature-one'], stdout: out).run).to eq(0)

      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')

      expect(File.directory?(target_dir)).to be(false)
      expect(out.string).to include('Dry run: previewing worktree setup without making changes')
      expect(out.string).to include("Would create '#{configuration.branch_prefix}/feature-one' from 'origin/main'")
      expect(out.string).to match(/Would bootstrap \.env \(DEV_PORT=\d+, WORKTREE_DATABASE_SUFFIX=_feature_one\)/)
      expect(out.string).to include('Dry run complete')
      expect(out.string).to include('No changes were made.')
    end

    it 'dry-runs an auto-picked bundled name without retiring it' do
      out = StringIO.new

      expect(build_command(argv: ['--dry-run'], stdout: out).run).to eq(0)

      expect(out.string).to include("Selected cities name 'daegu'")
      expect(out.string).to include("Would retire bundled name 'daegu'")
      expect(File.exist?(configuration.used_names_file)).to be(false)
      expect(File.directory?(File.join(configuration.workspace_root, 'app', 'daegu'))).to be(false)
    end

    it 'auto-picks a bundled name and retires it' do
      out = StringIO.new
      expect(build_command(stdout: out).run).to eq(0)

      expect(File.read(configuration.used_names_file)).to include("daegu\tapp\t")
      expect(out.string).to include("Selected cities name 'daegu'")
    end

    it 'skips malformed bundled names during auto-pick' do
      File.write(File.join(configuration.name_sources_path, 'cities.txt'), "bad name\nseoul/station\ngood-name\n")
      out = StringIO.new
      err = StringIO.new

      expect(build_command(stdout: out, stderr: err).run).to eq(0)
      expect(out.string).to include("Selected cities name 'good-name'")
      expect(err.string).to eq('')
    end

    it 'attaches an existing local branch when confirmed' do
      git!('-C', repo_path, 'branch', '🚂/existing', 'main')
      out = StringIO.new

      expect(build_command(argv: ['existing'], stdin: tty_input("yes\n"), stdout: out).run).to eq(0)
      expect(git_output('-C', File.join(configuration.workspace_root, 'app', 'existing'), 'branch', '--show-current'))
        .to eq('🚂/existing')
      expect(out.string).to include('Attach a new worktree to it?')
    end

    it 'dry-runs attaching an existing local branch without creating a worktree' do
      git!('-C', repo_path, 'branch', '🚂/existing', 'main')
      out = StringIO.new
      prompt = "Would confirm: Branch '🚂/existing' already exists locally. " \
               'Attach a new worktree to it?'

      expect(build_command(argv: ['--dry-run', 'existing'], stdout: out).run).to eq(0)

      expect(File.directory?(File.join(configuration.workspace_root, 'app', 'existing'))).to be(false)
      expect(out.string).to include(prompt)
      expect(out.string).to include("Would attach existing local branch '🚂/existing'")
    end

    it 'uses WT_WORKSPACES_ROOT as an explicit nested override' do
      out = StringIO.new
      explicit_root = File.join(tmpdir, 'env-workspaces')

      command = build_command(argv: ['from-env'], stdout: out, env: { 'WT_WORKSPACES_ROOT' => explicit_root })

      expect(command.run).to eq(0)

      target_dir = File.join(explicit_root, 'app', 'from-env')
      expect(File.directory?(target_dir)).to be(true)
      expect(out.string).to include("Root:   #{explicit_root}")
    end

    it 'reuses an existing matching worktree when confirmed' do
      build_command(argv: ['feature-one']).run
      out = StringIO.new

      expect(build_command(argv: ['feature-one'], stdin: tty_input("yes\n"), stdout: out).run).to eq(0)
      expect(out.string).to include('Reuse it?')
      expect(out.string).to include('Reusing existing worktree')
    end

    it 'dry-runs reusing an existing matching worktree' do
      build_command(argv: ['feature-one']).run
      out = StringIO.new

      expect(build_command(argv: ['--dry-run', 'feature-one'], stdout: out).run).to eq(0)

      expect(out.string).to include('Would confirm: Worktree already exists at')
      expect(out.string).to include('Would reuse existing worktree at')
      expect(out.string).to include('Dry run complete')
      expect(out.string).to include('No changes were made.')
    end

    it 'dry-runs removing an existing target path without deleting it' do
      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      FileUtils.mkdir_p(target_dir)
      File.write(File.join(target_dir, 'keep.txt'), "still here\n")
      out = StringIO.new
      prompt = "Would confirm: Target path '#{target_dir}' already exists. " \
               'Remove it and recreate the worktree?'

      expect(build_command(argv: ['--dry-run', 'feature-one'], stdout: out).run).to eq(0)

      expect(File.directory?(target_dir)).to be(true)
      expect(File.read(File.join(target_dir, 'keep.txt'))).to eq("still here\n")
      expect(out.string).to include(prompt)
      expect(out.string).to include("Would remove existing target path '#{target_dir}'")
      expect(out.string).to include("Would create '#{configuration.branch_prefix}/feature-one' from 'origin/main'")
    end

    it 'uses git worktree remove for a registered target before recreating it' do
      build_command(argv: ['feature-one']).run
      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      out = StringIO.new

      git!('-C', target_dir, 'switch', '-c', 'other-branch')

      expect(build_command(argv: ['feature-one'], stdin: tty_input("yes\nyes\n"), stdout: out).run).to eq(0)
      expect(git_output('-C', target_dir, 'branch', '--show-current')).to eq('🚂/feature-one')
      expect(git_output('-C', repo_path, 'worktree', 'list', '--porcelain'))
        .to include("worktree #{File.realpath(target_dir)}")
      expect(out.string).to include("Removing registered worktree at '#{target_dir}'")
    end

    it 'rejects a retired bundled name for a new branch' do
      FileUtils.mkdir_p(File.dirname(configuration.used_names_file))
      File.write(configuration.used_names_file, "daegu\tapp\t2026-03-29T00:00:00Z\n")
      err = StringIO.new

      expect(build_command(argv: ['daegu'], stderr: err).run).to eq(1)
      expect(err.string).to include("Bundled name 'daegu' has already been used and retired")
    end

    context 'with the implicit project-relative default root' do
      let(:workspace_root_override) { nil }

      it 'creates worktrees in a sibling <project>.worktrees directory' do
        out = StringIO.new

        expect(build_command(argv: ['feature-one'], stdout: out).run).to eq(0)

        target_dir = File.join(default_workspaces_root, 'feature-one')
        expect(File.directory?(target_dir)).to be(true)
        expect(git_output('-C', target_dir, 'branch', '--show-current')).to eq('🚂/feature-one')
        expect(out.string).not_to include('Root:')
      end
    end
  end

  private

  def bootstrap_git_repository
    git!('init', '--bare', '--initial-branch=main', origin_path)
    git!('init', '--initial-branch=main', repo_path)
    git!('-C', repo_path, 'remote', 'add', 'origin', origin_path)
    File.write(File.join(repo_path, 'README.md'), "# demo\n")
    git!('-C', repo_path, 'add', 'README.md')
    git!('-C', repo_path, 'commit', '-m', 'Initial commit')
    git!('-C', repo_path, 'push', '-u', 'origin', 'main')
    git!('-C', repo_path, 'remote', 'set-head', 'origin', '-a')
  end

  def git!(*args)
    stdout_str, stderr_str, status = Open3.capture3(git_env, 'git', *args)
    return stdout_str if status.success?

    raise [stdout_str, stderr_str].join("\n")
  end

  def git_output(*args) = git!(*args).strip

  def tty_input(content)
    StringIO.new(content).tap { |io| io.define_singleton_method(:tty?) { true } }
  end

  def git_env
    {
      'GIT_AUTHOR_NAME' => 'Test User',
      'GIT_AUTHOR_EMAIL' => 'test@example.com',
      'GIT_COMMITTER_NAME' => 'Test User',
      'GIT_COMMITTER_EMAIL' => 'test@example.com',
      'GIT_CONFIG_NOSYSTEM' => '1',
      'GIT_CONFIG_COUNT' => '2',
      'GIT_CONFIG_KEY_0' => 'commit.gpgsign',
      'GIT_CONFIG_VALUE_0' => 'false',
      'GIT_CONFIG_KEY_1' => 'tag.gpgsign',
      'GIT_CONFIG_VALUE_1' => 'false'
    }
  end
end
