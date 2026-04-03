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
      # Disable post-create steps by default so tests that don't opt in are unaffected
      config.post_create_command = false
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

  def write_repo_file(relative_path, content)
    absolute_path = File.join(repo_path, relative_path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, content)
    absolute_path
  end

  def managed_wt_template
    File.read(File.expand_path('../../../lib/generators/rails/worktrees/templates/bin/wt', __dir__))
  end

  def install_worktrees_files(initializer: Rails::Worktrees::InitializerUpdater.default_content)
    wt_path = write_repo_file('bin/wt', managed_wt_template)
    FileUtils.chmod(0o755, wt_path)
    write_repo_file('config/initializers/rails_worktrees.rb', initializer)
    write_repo_file(
      'config/database.yml',
      "development:\n  database: demo_app_development<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>\n"
    )
  end

  def build_command(argv: [], env: {}, cwd: repo_path, **io_overrides)
    # Use only path-related variables from the host to allow tools like `git` to run
    base_env = ENV.to_h.slice('PATH', 'HOME')
    io = {
      stdin: StringIO.new,
      stdout: StringIO.new,
      stderr: StringIO.new
    }.merge(io_overrides)

    described_class.new(
      argv: argv,
      io: io,
      env: base_env.merge(env),
      cwd: cwd,
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
      expect(out.string).to include('Dry run: previewing worktree changes without applying them')
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

    it 'removes a merged worktree and deletes its local branch' do
      build_command(argv: ['feature-one']).run
      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      out = StringIO.new

      commit_in_worktree(target_dir, 'feature.txt', "hello\n")
      merge_worktree_branch('🚂/feature-one')

      expect(build_command(argv: %w[remove feature-one], stdout: out).run).to eq(0)

      expect(File.exist?(target_dir)).to be(false)
      expect(local_branch_exists?('🚂/feature-one')).to be(false)
      expect(out.string).to include("Removed 'feature-one'")
    end

    it 'supports wt delete as an alias for wt remove' do
      build_command(argv: ['feature-one']).run
      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')

      commit_in_worktree(target_dir, 'feature.txt', "hello\n")
      merge_worktree_branch('🚂/feature-one')

      expect(build_command(argv: %w[delete feature-one]).run).to eq(0)

      expect(File.exist?(target_dir)).to be(false)
      expect(local_branch_exists?('🚂/feature-one')).to be(false)
    end

    it 'reports remove alias usage with supported flags' do
      err = StringIO.new

      expect(build_command(argv: ['delete', '--force'], stderr: err).run).to eq(1)

      expect(err.string).to include('Usage: wt delete [--dry-run] [--force] <worktree-name>')
    end

    it 'refuses to remove an unmerged branch without --force' do
      build_command(argv: ['feature-one']).run
      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      err = StringIO.new

      commit_in_worktree(target_dir, 'feature.txt', "hello\n")

      expect(build_command(argv: %w[remove feature-one], stderr: err).run).to eq(1)

      expect(File.directory?(target_dir)).to be(true)
      expect(local_branch_exists?('🚂/feature-one')).to be(true)
      expect(err.string).to include('is not merged into origin/main')
      expect(err.string).to include('--force')
    end

    it 'force-removes an unmerged worktree and its local branch' do
      build_command(argv: ['feature-one']).run
      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      out = StringIO.new

      commit_in_worktree(target_dir, 'feature.txt', "hello\n")

      expect(build_command(argv: ['remove', '--force', 'feature-one'], stdout: out).run).to eq(0)

      expect(File.exist?(target_dir)).to be(false)
      expect(local_branch_exists?('🚂/feature-one')).to be(false)
      expect(out.string).to include("Removed 'feature-one'")
    end

    it 'refuses to remove the current worktree from inside itself' do
      build_command(argv: ['feature-one']).run
      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      err = StringIO.new

      expect(build_command(argv: %w[remove feature-one], cwd: target_dir, stderr: err).run).to eq(1)

      expect(err.string).to include('Cannot remove the current worktree from inside itself')
      expect(File.directory?(target_dir)).to be(true)
      expect(local_branch_exists?('🚂/feature-one')).to be(true)
    end

    it 'removes a merged sibling worktree when run from another worktree' do
      build_command(argv: ['feature-one']).run
      build_command(argv: ['runner']).run
      target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      runner_dir = File.join(configuration.workspace_root, 'app', 'runner')

      commit_in_worktree(target_dir, 'feature.txt', "hello\n")
      merge_worktree_branch('🚂/feature-one')

      expect(build_command(argv: %w[remove feature-one], cwd: runner_dir).run).to eq(0)

      expect(File.exist?(target_dir)).to be(false)
      expect(local_branch_exists?('🚂/feature-one')).to be(false)
      expect(File.directory?(runner_dir)).to be(true)
      expect(local_branch_exists?('🚂/runner')).to be(true)
    end

    it 'prunes merged wt-managed worktrees and skips the current worktree' do # rubocop:disable RSpec/ExampleLength
      build_command(argv: ['feature-one']).run
      build_command(argv: ['runner']).run
      merged_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      runner_dir = File.join(configuration.workspace_root, 'app', 'runner')
      out = StringIO.new

      commit_in_worktree(merged_dir, 'feature.txt', "hello\n")
      merge_worktree_branch('🚂/feature-one')

      expect(
        build_command(argv: ['prune'], cwd: runner_dir, stdin: tty_input("yes\n"), stdout: out).run
      ).to eq(0)

      expect(File.exist?(merged_dir)).to be(false)
      expect(local_branch_exists?('🚂/feature-one')).to be(false)
      expect(File.directory?(runner_dir)).to be(true)
      expect(local_branch_exists?('🚂/runner')).to be(true)
      expect(out.string).to include('Found 1 merged worktree created by wt')
      expect(out.string).to include("feature-one => #{merged_dir} (🚂/feature-one)")
    end

    it 'dry-runs prune without deleting anything' do
      build_command(argv: ['feature-one']).run
      merged_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      out = StringIO.new

      commit_in_worktree(merged_dir, 'feature.txt', "hello\n")
      merge_worktree_branch('🚂/feature-one')

      expect(build_command(argv: ['prune', '--dry-run'], stdout: out).run).to eq(0)

      expect(File.directory?(merged_dir)).to be(true)
      expect(local_branch_exists?('🚂/feature-one')).to be(true)
      expect(out.string).to include('Dry run: previewing worktree changes without applying them')
      expect(out.string).to include('Would prune 1 merged worktree')
      expect(out.string).to include('No changes were made.')
    end

    it 'resolves repository context once when pruning candidates' do
      build_command(argv: ['feature-one']).run
      merged_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
      out = StringIO.new
      command = build_command(argv: ['prune', '--dry-run'], stdout: out)

      commit_in_worktree(merged_dir, 'feature.txt', "hello\n")
      merge_worktree_branch('🚂/feature-one')

      allow(command).to receive(:resolve_repository_context).and_call_original

      expect(command.run).to eq(0)
      expect(command).to have_received(:resolve_repository_context).once
    end

    it 'uses a non-forced branch delete unless --force was requested' do
      command = build_command

      allow(command).to receive(:ensure_local_branch_removable!)
      allow(command).to receive(:info)
      allow(command).to receive(:git!)

      command.send(:delete_local_branch, '🚂/feature-one', force: false)

      expect(command).to have_received(:ensure_local_branch_removable!).with('🚂/feature-one', force: false)
      expect(command).to have_received(:info).with("Deleting local branch '🚂/feature-one'")
      expect(command).to have_received(:git!).with('branch', '-d', '🚂/feature-one')
    end

    it 'uses a forced branch delete only when --force was requested' do
      command = build_command

      allow(command).to receive(:ensure_local_branch_removable!)
      allow(command).to receive(:info)
      allow(command).to receive(:git!)

      command.send(:delete_local_branch, '🚂/feature-one', force: true)

      expect(command).to have_received(:ensure_local_branch_removable!).with('🚂/feature-one', force: true)
      expect(command).to have_received(:info).with("Deleting local branch '🚂/feature-one'")
      expect(command).to have_received(:git!).with('branch', '-D', '🚂/feature-one')
    end

    it 'reports doctor issues when run outside a git repository' do
      err = StringIO.new

      expect(build_command(argv: ['doctor'], cwd: tmpdir, stderr: err).run).to eq(1)

      expect(err.string).to include('Run wt doctor from inside a Git repository.')
    end

    it 'reports fixable installer drift and becomes healthy after wt update' do
      install_worktrees_files(initializer: <<~RUBY)
        Rails::Worktrees.configure do |config|
          config.bootstrap_env = false
        end
      RUBY
      doctor_out = StringIO.new
      doctor_err = StringIO.new

      expect(build_command(argv: ['doctor'], stdout: doctor_out, stderr: doctor_err).run).to eq(1)
      expect(doctor_err.string).to include('config/initializers/rails_worktrees.rb can be updated automatically.')

      expect(build_command(argv: ['update']).run).to eq(0)

      refreshed_out = StringIO.new
      refreshed_err = StringIO.new
      expect(build_command(argv: ['doctor'], stdout: refreshed_out, stderr: refreshed_err).run).to eq(0)
      expect(refreshed_out.string).to include('Doctor found no issues.')
    end

    it 'dry-runs wt update without changing files' do
      install_worktrees_files(initializer: <<~RUBY)
        Rails::Worktrees.configure do |config|
          config.bootstrap_env = false
        end
      RUBY
      original_initializer = File.read(File.join(repo_path, 'config/initializers/rails_worktrees.rb'))
      out = StringIO.new

      expect(build_command(argv: ['update', '--dry-run'], stdout: out).run).to eq(0)

      expect(File.read(File.join(repo_path, 'config/initializers/rails_worktrees.rb'))).to eq(original_initializer)
      expect(out.string).to include('Would update config/initializers/rails_worktrees.rb')
      expect(out.string).to include('Dry run complete')
      expect(out.string).to include('No changes were made.')
    end

    it 'restores executable permissions for managed wrapper scripts during wt update' do
      install_worktrees_files
      wt_path = File.join(repo_path, 'bin', 'wt')
      FileUtils.chmod(0o644, wt_path)

      expect(File.executable?(wt_path)).to be(false)
      expect(build_command(argv: ['update']).run).to eq(0)
      expect(File.executable?(wt_path)).to be(true)
    end

    it 'resolves repository context once when applying wt update' do
      install_worktrees_files(initializer: <<~RUBY)
        Rails::Worktrees.configure do |config|
          config.bootstrap_env = false
        end
      RUBY
      out = StringIO.new
      command = build_command(argv: ['update', '--dry-run'], stdout: out)

      allow(command).to receive(:resolve_repository_context).and_call_original

      expect(command.run).to eq(0)
      expect(command).to have_received(:resolve_repository_context).once
    end

    it 'refuses to overwrite a managed symlink during wt update' do
      install_worktrees_files
      outside_target = File.join(tmpdir, 'outside-wt')
      File.write(outside_target, "#!/usr/bin/env ruby\nputs 'outside'\n")
      FileUtils.rm_f(File.join(repo_path, 'bin', 'wt'))
      File.symlink(outside_target, File.join(repo_path, 'bin', 'wt'))
      err = StringIO.new

      expect(build_command(argv: ['update'], stderr: err).run).to eq(1)

      expect(err.string).to include('Refusing to overwrite symlinked path')
      expect(File.read(outside_target)).to eq("#!/usr/bin/env ruby\nputs 'outside'\n")
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

    context 'with post-create setup steps' do
      before do
        # Switch to built-in mode with all steps off; each example opts in to what it needs
        configuration.post_create_command = nil
        configuration.run_bundle_install = false
        configuration.run_yarn_install = false
        configuration.run_db_prepare = false
        configuration.run_test_db_prepare = false
        configuration.run_test_assets_precompile = false
        configuration.link_credential_keys = false
        configuration.link_test_credential_key = false
        configuration.link_production_credential_key = false
      end

      it 'skips all post-create steps when post_create_command is false' do
        configuration.post_create_command = false
        configuration.run_bundle_install = true
        out = StringIO.new

        expect(build_command(argv: ['feature-one'], stdout: out).run).to eq(0)
        expect(out.string).not_to include('Installing gems')
      end

      it 'dry-runs post-create steps without executing them' do
        configuration.run_bundle_install = true
        configuration.run_db_prepare = true
        out = StringIO.new

        expect(build_command(argv: ['--dry-run', 'feature-one'], stdout: out).run).to eq(0)
        expect(out.string).to include('Would run: bundle install')
        expect(out.string).to include('Would run: RAILS_ENV=development bin/rails db:prepare')
        expect(out.string).not_to include('Installing gems...')
      end

      it 'runs a custom post_create_command in the target directory' do
        configuration.post_create_command = 'echo "custom-setup-ran"'
        out = StringIO.new

        expect(build_command(argv: ['feature-one'], stdout: out).run).to eq(0)
        expect(out.string).to include('custom-setup-ran')
      end

      it 'returns exit 1 when the custom command fails' do
        configuration.post_create_command = 'exit 1'
        err = StringIO.new

        expect(build_command(argv: ['feature-one'], stderr: err).run).to eq(1)
        expect(err.string).to include('Command failed')
      end

      it 'does not run post-create steps on worktree reuse' do
        build_command(argv: ['feature-one']).run
        configuration.post_create_command = 'echo "should-not-run"'
        out = StringIO.new

        expect(build_command(argv: ['feature-one'], stdin: tty_input("yes\n"), stdout: out).run).to eq(0)
        expect(out.string).not_to include('should-not-run')
      end

      it 'links a credential key from a peer worktree after creation' do
        configuration.link_credential_keys = true

        # seed the primary checkout with a development.key
        write_repo_file('config/credentials/development.key', 'dev-secret')

        out = StringIO.new
        expect(build_command(argv: ['feature-one'], stdout: out).run).to eq(0)

        target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
        linked_key = File.join(target_dir, 'config/credentials', 'development.key')

        expect(File.symlink?(linked_key)).to be(true)
        expect(out.string).to include('Linked development.key')
      end

      it 'dry-runs credential key linking without creating a symlink' do
        configuration.link_credential_keys = true
        write_repo_file('config/credentials/development.key', 'dev-secret')

        out = StringIO.new
        expect(build_command(argv: ['--dry-run', 'feature-one'], stdout: out).run).to eq(0)

        target_dir = File.join(configuration.workspace_root, 'app', 'feature-one')
        linked_key = File.join(target_dir, 'config/credentials', 'development.key')

        expect(File.symlink?(linked_key)).to be(false)
        expect(out.string).to include('Would link development.key')
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

  def local_branch_exists?(branch_name)
    _stdout_str, _stderr_str, status = Open3.capture3(
      git_env, 'git', '-C', repo_path, 'show-ref', '--verify', '--quiet', "refs/heads/#{branch_name}"
    )
    status.success?
  end

  def commit_in_worktree(path, file_name, content)
    File.write(File.join(path, file_name), content)
    git!('-C', path, 'add', file_name)
    git!('-C', path, 'commit', '-m', "Add #{file_name}")
  end

  def merge_worktree_branch(branch_name)
    git!('-C', repo_path, 'merge', '--no-ff', branch_name, '-m', "Merge #{branch_name}")
    git!('-C', repo_path, 'push', 'origin', 'main')
  end

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
