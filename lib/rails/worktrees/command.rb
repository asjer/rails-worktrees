require 'fileutils'
require_relative 'command/environment_support'
require_relative 'command/git_operations'
require_relative 'command/name_picking'
require_relative 'command/output'
require_relative 'command/post_create_support'
require_relative 'command/workspace_paths'

module Rails
  module Worktrees
    # Creates or attaches worktrees for the current repository.
    # rubocop:disable Metrics/ClassLength
    class Command
      REMOVE_SUBCOMMANDS = %w[remove delete].freeze
      DOCTOR_SUBCOMMAND = 'doctor'.freeze
      SETUP_SUBCOMMAND = 'setup'.freeze
      UPDATE_SUBCOMMAND = 'update'.freeze

      include GitOperations
      include EnvironmentSupport
      include NamePicking
      include Output
      include PostCreateSupport
      include WorkspacePaths

      def initialize(argv:, io:, env:, cwd:, configuration:)
        @argv = argv.dup
        @stdin = io.fetch(:stdin)
        @stdout = io.fetch(:stdout)
        @stderr = io.fetch(:stderr)
        @env = env
        @cwd = cwd
        @configuration = configuration
        extract_flags!
      end

      def run
        meta_command_result = handle_meta_command
        return meta_command_result unless meta_command_result.nil?

        execute_requested_command
      rescue Error => e
        @stderr.puts("Error: #{e.message}")
        1
      end

      private

      def dry_run? = @dry_run

      def force? = @force

      def skip_setup? = @skip_setup

      def extract_flags!
        @dry_run = extract_flag!('--dry-run')
        @force = extract_flag!('--force')
        @skip_setup = extract_flag!('--skip-setup')
      end

      def extract_flag!(flag)
        extracted = false
        @argv.reject! do |arg|
          next false unless arg == flag

          extracted = true
          true
        end
        extracted
      end

      def remove_subcommand?
        REMOVE_SUBCOMMANDS.include?(@argv.first)
      end

      def prune_subcommand?
        @argv.first == 'prune'
      end

      def doctor_subcommand?
        @argv.first == DOCTOR_SUBCOMMAND
      end

      def setup_subcommand?
        @argv.first == SETUP_SUBCOMMAND
      end

      def update_subcommand?
        @argv.first == UPDATE_SUBCOMMAND
      end

      def execute_requested_command
        handler = requested_command_handler
        return handler.call if handler
        return usage_error if invalid_worktree_command?

        execute_worktree_command
      end

      def requested_command_handler
        case @argv.first
        when DOCTOR_SUBCOMMAND then -> { execute_doctor_command }
        when SETUP_SUBCOMMAND then -> { execute_setup_command }
        when UPDATE_SUBCOMMAND then -> { execute_update_command }
        when 'prune' then -> { execute_prune_command }
        else
          -> { execute_remove_command } if remove_subcommand?
        end
      end

      def invalid_worktree_command?
        @argv.length > 1 || force?
      end

      def execute_worktree_command
        require_git_repo
        announce_dry_run if dry_run?
        context = resolve_worktree_context

        if File.exist?(context[:target_dir])
          return finish_reuse(context) if worktree_matches_branch?(context)

          confirm_and_remove_target(context[:target_dir])
        end

        prepare_target_parent(context[:target_dir])
        attach_or_create_worktree(context)
        finish(context)
      end

      def execute_setup_command
        validate_setup_args!
        announce_dry_run if dry_run?

        context = resolve_setup_context(target_reference: setup_target_reference)
        validate_setup_target!(context)

        complete_setup_flow(context, success_message: 'Setup complete')
      end

      def execute_remove_command
        require_git_repo
        announce_dry_run if dry_run?
        validate_remove_args!

        context = resolve_worktree_context(explicit_worktree_name: @argv.fetch(1))
        removal_status = removal_status_for(context)

        ensure_removable!(context, **removal_status)
        return complete_remove_dry_run(context, **removal_status) if dry_run?

        perform_remove(context, **removal_status)
      end

      def validate_remove_args!
        raise Error, "Usage: wt #{@argv.first} [--dry-run] [--force] <worktree-name>" unless @argv.length == 2
      end

      def removal_status_for(context)
        {
          worktree_exists: File.exist?(context[:target_dir]),
          branch_exists: branch_exists_locally?(context[:branch_name])
        }
      end

      def perform_remove(context, worktree_exists:, branch_exists:)
        remove_target_path(context[:target_dir]) if worktree_exists
        delete_local_branch(context[:branch_name], force: force?) if branch_exists

        success("Removed '#{context[:worktree_name]}'")
        print_context_summary(context, env_values: nil)
        0
      end

      def execute_prune_command
        require_git_repo
        announce_dry_run if dry_run?
        validate_prune_args!

        candidates = prune_candidates
        return complete_prune_noop if candidates.empty?

        prepare_prune(candidates)
        return complete_prune_dry_run(candidates) if dry_run?

        perform_prune(candidates)

        success("Pruned #{candidates.length} worktree#{'s' unless candidates.length == 1}")
        0
      end

      # rubocop:disable Metrics/MethodLength
      def execute_doctor_command
        validate_doctor_args!

        unless git_success?('rev-parse', '--is-inside-work-tree')
          checks = [doctor_check(category: :git, status: :warning,
                                 headline: 'Run wt doctor from inside a Git repository.')]
          print_doctor_report(checks)
          return 1
        end

        repository = resolve_repository_context
        checks = project_maintenance_report(repository[:current_root]).checks + doctor_worktree_checks(repository)
        print_doctor_report(checks)

        checks.any? { |check| check.fixable? || check.warning? } ? 1 : 0
      end
      # rubocop:enable Metrics/MethodLength

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def execute_update_command
        require_git_repo
        validate_update_args!
        announce_dry_run if dry_run?

        repository_root = resolve_repository_context[:current_root]
        current_root = update_target_root(repository_root)
        report = project_maintenance_report(current_root)
        updated_count = 0
        identical_count = 0
        skipped_count = 0

        report.checks.each do |check|
          if check.fixable?
            apply_maintenance_check(check, current_root: current_root)
            updated_count += 1
          elsif check.ok?
            identical_count += 1
            info(check.headline)
          else
            skipped_count += 1
            warning(check.headline)
            check.messages.each { |message| info(message) }
          end
        end

        complete_update(updated_count:, identical_count:, skipped_count:)
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def validate_prune_args!
        raise Error, 'Usage: wt prune' unless @argv.length == 1
        raise Error, 'The --force flag is only supported with wt remove.' if force?
        raise Error, 'The --skip-setup flag is only supported when creating a worktree.' if skip_setup?
      end

      def validate_doctor_args!
        raise Error, 'Usage: wt doctor' unless @argv.length == 1
        raise Error, 'wt doctor does not support --dry-run.' if dry_run?
        raise Error, 'The --force flag is only supported with wt remove.' if force?
        raise Error, 'The --skip-setup flag is only supported when creating a worktree.' if skip_setup?
      end

      def validate_setup_args!
        raise Error, 'Usage: wt setup [--dry-run] [path|name]' unless [1, 2].include?(@argv.length)
        raise Error, 'The --force flag is only supported with wt remove.' if force?
        raise Error, 'The --skip-setup flag is only supported when creating a worktree.' if skip_setup?
      end

      def validate_update_args!
        raise Error, 'Usage: wt update [--dry-run] [path]' unless [1, 2].include?(@argv.length)
        raise Error, 'The --force flag is only supported with wt remove.' if force?
        raise Error, 'The --skip-setup flag is only supported when creating a worktree.' if skip_setup?
      end

      def update_target_root(repository_root)
        return repository_root unless @argv[1]

        target_root = canonical_path(File.expand_path(@argv[1], @cwd))
        raise Error, "Update target does not exist: #{target_root}" unless File.directory?(target_root)

        assert_within_root!(
          target_root,
          repository_root,
          "Refusing to update a path outside the current Git repository: #{target_root}"
        )
        target_root
      end

      def announce_prune_candidates(candidates)
        info("Found #{candidates.length} merged worktree#{'s' unless candidates.length == 1} created by wt:")
      end

      def prepare_prune(candidates)
        announce_prune_candidates(candidates)
        print_prune_candidates(candidates)
        confirm_or_abort!(prune_confirmation_prompt(candidates.length))
      end

      def prune_confirmation_prompt(count)
        branches = count == 1 ? 'its local branch' : 'their local branches'
        "Delete #{count} merged worktree#{'s' unless count == 1} and #{branches}?"
      end

      def perform_prune(candidates)
        candidates.each do |context|
          remove_target_path(context[:target_dir])
          delete_local_branch(context[:branch_name], force: false)
        end
      end

      def resolve_worktree_context(explicit_worktree_name: nil, repository: nil)
        repository ||= resolve_repository_context
        project_name = repository[:project_name]
        workspaces = repository[:workspaces]
        worktree_name = resolved_worktree_name(project_name, workspaces, explicit_worktree_name)

        repository.merge(
          worktree_name: worktree_name,
          branch_name: branch_name_for(worktree_name),
          target_dir: target_dir_for(project_name, worktree_name, workspaces)
        )
      end

      def resolve_setup_context(target_reference: nil, repository: nil)
        if setup_target_name?(target_reference)
          return resolve_named_setup_context(target_reference, repository: repository)
        end

        resolve_path_setup_context(target_reference, repository: repository)
      end

      def resolve_path_setup_context(target_reference, repository: nil)
        target_dir = resolved_setup_target_path(target_reference)
        repository ||= target_reference ? resolve_repository_context_for(target_dir) : resolve_repository_context
        branch_name = current_checkout_branch_at(target_dir)

        repository.merge(
          worktree_name: setup_identity_for(repository[:current_root], branch_name),
          branch_name: display_branch_name(branch_name, target_dir: repository[:current_root]),
          target_dir: repository[:current_root],
          peer_roots: peer_roots_for(repository[:current_root])
        )
      end

      def resolve_named_setup_context(worktree_name, repository: nil)
        repository ||= resolve_repository_context
        context = resolve_worktree_context(explicit_worktree_name: worktree_name, repository: repository)
        branch_name = resolved_named_setup_branch_name(context)

        context.merge(
          branch_name: display_branch_name(branch_name, target_dir: context[:target_dir]),
          peer_roots: peer_roots_for(context[:target_dir])
        )
      end

      def resolved_named_setup_branch_name(context)
        return context[:branch_name] unless File.directory?(context[:target_dir])

        current_checkout_branch_at(context[:target_dir])
      end

      def setup_target_reference = @argv[1]

      def setup_target_name?(target_reference)
        !target_reference.nil? && !path_like_setup_target?(target_reference)
      end

      def resolved_setup_target_path(target_path)
        return @cwd if target_path.nil?

        File.expand_path(target_path, @cwd)
      end

      def path_like_setup_target?(target_reference)
        target_reference.start_with?('/', '.', '~') || target_reference.include?(File::SEPARATOR)
      end

      def resolved_worktree_name(project_name, workspaces, explicit_worktree_name)
        return validate_worktree_name(explicit_worktree_name) if explicit_worktree_name

        resolve_worktree_name(project_name, workspaces)
      end

      def attach_or_create_worktree(context)
        branch, target = context.values_at(:branch_name, :target_dir)

        if branch_exists_locally?(branch)
          confirm_or_abort!("Branch '#{branch}' already exists locally. Attach a new worktree to it?")
          attach_existing_branch_worktree(branch, target)
        elsif branch_exists_on_origin?(branch)
          confirm_or_abort!("Branch '#{branch}' already exists on origin. Create a local tracking worktree?")
          track_remote_branch_worktree(branch, target)
        else
          create_fresh_branch_worktree(context)
        end
      end

      def create_fresh_branch_worktree(context)
        reject_retired_name_for_new_branch(context[:worktree_name])
        create_new_branch_worktree(context[:branch_name], context[:target_dir])
      end

      def finish(context)
        settle_retired_name(context[:worktree_name], context[:project_name], dry_run: dry_run?)
        complete_setup_flow(
          context,
          success_message: skip_setup? ? 'Worktree created' : 'Worktree ready',
          run_post_create: !skip_setup?
        )
      end

      def complete_dry_run_after_setup(context, bootstrap_result, run_post_create: true)
        preview_post_create_steps(context, bootstrapped_env: bootstrap_result&.values) if run_post_create
        info('Would skip setup steps; run `wt setup` inside the checkout when you are ready.') unless run_post_create
        complete_dry_run(context, env_values: bootstrap_result&.values)
      end

      def complete_created_worktree(context, bootstrap_result, success_message:, run_post_create: true)
        unless run_post_create
          return complete_created_worktree_without_setup(context, bootstrap_result, success_message)
        end

        result = run_post_create_steps(context, bootstrapped_env: bootstrap_result&.values)
        return result unless result.zero?

        success(success_message)
        print_context_summary(context, env_values: bootstrap_result&.values)
        0
      end

      def complete_created_worktree_without_setup(context, bootstrap_result, success_message)
        success(success_message)
        print_context_summary(context, env_values: bootstrap_result&.values)
        info('Setup skipped. Run `wt setup` inside the checkout when you are ready.')
        0
      end

      def complete_setup_flow(context, success_message:, run_post_create: true)
        bootstrap_result = bootstrap_worktree_environment(context)

        return complete_dry_run_after_setup(context, bootstrap_result, run_post_create: run_post_create) if dry_run?

        complete_created_worktree(
          context,
          bootstrap_result,
          success_message: success_message,
          run_post_create: run_post_create
        )
      end

      def finish_reuse(context)
        target, branch = context.values_at(:target_dir, :branch_name)

        confirm_or_abort!("Worktree already exists at '#{target}' on '#{branch}'. Reuse it?")
        settle_retired_name(context[:worktree_name], context[:project_name], dry_run: dry_run?)
        return complete_reuse_dry_run(context, target: target, branch: branch) if dry_run?

        bootstrap_result = bootstrap_worktree_environment(context)
        success('Reusing existing worktree')
        print_context_summary(context, target_dir: target, branch_name: branch, env_values: bootstrap_result&.values)
        0
      end

      def worktree_matches_branch?(context)
        target = context[:target_dir]
        return false unless git_success?('-C', target, 'rev-parse', '--is-inside-work-tree')

        existing = git_capture('-C', target, 'branch', '--show-current', allow_failure: true).strip
        existing == context[:branch_name]
      end

      def confirm_and_remove_target(target_dir)
        confirm_or_abort!("Target path '#{target_dir}' already exists. Remove it and recreate the worktree?")
        return info("Would remove existing target path '#{target_dir}'") if dry_run?

        remove_target_path(target_dir)
      end

      def branch_name_for(worktree_name)
        "#{@configuration.branch_prefix}/#{worktree_name}"
      end

      def validate_setup_target!(context)
        raise Error, "Setup target does not exist: #{context[:target_dir]}" unless File.directory?(context[:target_dir])

        rails_bin = File.join(context[:target_dir], 'bin', 'rails')

        unless File.exist?(rails_bin)
          raise Error,
                "Setup target does not look like a Rails app. Expected #{rails_bin} to exist before running wt setup."
        end

        return if registered_worktree_path_for_setup?(context[:target_dir])

        warning(
          'Current checkout is not registered in git worktree list; peer credential key discovery may be limited.'
        )
      end

      def current_checkout_branch_at(target_dir)
        git_capture('-C', target_dir, 'branch', '--show-current', allow_failure: true).strip
      end

      def registered_worktree_path_for_setup?(target_dir)
        normalized_target = canonical_path(target_dir)

        worktree_entries_for_checkout(target_dir).any? { |entry| entry[:path] == normalized_target }
      end

      def peer_roots_for(target_dir)
        normalized_target = canonical_path(target_dir)

        worktree_entries_for_checkout(target_dir)
          .map { |entry| entry[:path] }
          .reject { |path| path == normalized_target }
      end

      def worktree_entries_for_checkout(target_dir)
        git_capture('-C', target_dir, 'worktree', 'list', '--porcelain', allow_failure: true)
          .split("\n\n")
          .filter_map do |block|
            entry = parse_worktree_entry(block)
            entry[:path] ? entry : nil
          end
      end

      def setup_identity_for(target_dir, branch_name)
        stripped_branch = worktree_identity_from_branch(branch_name)
        return stripped_branch unless stripped_branch.empty?

        File.basename(target_dir)
      end

      def worktree_identity_from_branch(branch_name)
        branch_name = branch_name.to_s.strip
        return '' if branch_name.empty?

        worktree_name_for_branch(branch_name)
      end

      def display_branch_name(branch_name, target_dir: nil)
        branch_name = branch_name.to_s.strip
        return branch_name unless branch_name.empty?

        git_args = if target_dir.to_s.strip.empty?
                     ['rev-parse', '--short', 'HEAD']
                   else
                     ['-C', target_dir, 'rev-parse', '--short', 'HEAD']
                   end

        short_sha = git_capture(*git_args, allow_failure: true).strip
        short_sha.empty? ? '(detached HEAD)' : "(detached HEAD at #{short_sha})"
      end

      def ensure_removable!(context, worktree_exists:, branch_exists:)
        ensure_remove_target_exists!(context, worktree_exists: worktree_exists, branch_exists: branch_exists)
        ensure_not_removing_protected_checkout!(context)
        ensure_branch_not_checked_out_here!(context)
        ensure_branch_not_checked_out_elsewhere!(context)
        ensure_local_branch_removable!(context[:branch_name], force: force?) if branch_exists
      end

      def ensure_remove_target_exists!(context, worktree_exists:, branch_exists:)
        return if worktree_exists || branch_exists

        raise Error, "No worktree or local branch found for '#{context[:worktree_name]}'."
      end

      def ensure_not_removing_protected_checkout!(context)
        target_path = canonical_path(context[:target_dir])
        raise Error, 'Cannot remove the main checkout.' if target_path == canonical_path(context[:primary_root])

        return unless target_path == canonical_path(context[:current_root])

        raise Error,
              'Cannot remove the current worktree from inside itself. ' \
              'Run this command from the main checkout or another worktree.'
      end

      def ensure_branch_not_checked_out_here!(context)
        return unless current_checkout_branch == context[:branch_name]

        raise Error,
              "Branch '#{context[:branch_name]}' is checked out in the current worktree. " \
              'Run this command from the main checkout or another worktree.'
      end

      def ensure_branch_not_checked_out_elsewhere!(context)
        target_path = canonical_path(context[:target_dir])
        unexpected_paths = worktree_entries_for_branch(context[:branch_name])
                           .map { |entry| entry[:path] }
                           .reject { |path| path == target_path }
        return if unexpected_paths.empty?

        raise Error,
              "Branch '#{context[:branch_name]}' is checked out in another worktree at '#{unexpected_paths.first}'."
      end

      def prune_candidates
        repository = resolve_repository_context

        worktree_entries.filter_map do |entry|
          prune_candidate_for(entry, repository)
        end
      end

      def prune_candidate_for(entry, repository)
        branch_name = entry[:branch_name]
        return unless prunable_worktree_entry?(entry, branch_name, repository)

        context = resolve_worktree_context(
          explicit_worktree_name: worktree_name_for_branch(branch_name),
          repository: repository
        )
        return unless prune_target_matches_entry?(entry, context)

        context
      end

      def prunable_worktree_entry?(entry, branch_name, repository)
        wt_managed_branch?(branch_name) &&
          !protected_prune_path?(entry[:path], repository) &&
          !branch_checked_out_elsewhere_for_prune?(branch_name, entry[:path]) &&
          branch_exists_locally?(branch_name) &&
          branch_merged_into_default?(branch_name)
      end

      def branch_checked_out_elsewhere_for_prune?(branch_name, target_path)
        worktree_entries_for_branch(branch_name).any? { |other| other[:path] != target_path }
      end

      def prune_target_matches_entry?(entry, context)
        entry[:path] == canonical_path(context[:target_dir])
      end

      def protected_prune_path?(path, repository)
        path == repository[:primary_root] || path == repository[:current_root]
      end

      def wt_managed_branch?(branch_name)
        branch_name&.start_with?("#{@configuration.branch_prefix}/")
      end

      def worktree_name_for_branch(branch_name)
        branch_name.delete_prefix("#{@configuration.branch_prefix}/")
      end

      def project_maintenance_report(root)
        ::Rails::Worktrees::ProjectMaintenance.new(root: root).call
      end

      def doctor_worktree_checks(repository)
        [
          doctor_check(
            category: :git,
            status: :ok,
            headline: "Git repository detected at #{repository[:current_root]}."
          ),
          default_branch_doctor_check,
          stale_worktree_doctor_check
        ]
      end

      def default_branch_doctor_check
        doctor_check(
          category: :git,
          status: :ok,
          headline: "origin default branch resolves to '#{resolve_default_branch}'."
        )
      rescue Error => e
        doctor_check(category: :git, status: :warning, headline: e.message)
      end

      # rubocop:disable Metrics/MethodLength
      def stale_worktree_doctor_check
        stale_paths = worktree_entries.reject { |entry| File.directory?(entry[:path]) }
        if stale_paths.empty?
          doctor_check(category: :worktree, status: :ok, headline: 'No stale registered worktree paths found.')
        else
          doctor_check(
            category: :worktree,
            status: :warning,
            headline: "Found #{stale_paths.length} stale registered worktree " \
                      "path#{'s' unless stale_paths.length == 1}.",
            messages: stale_paths.map { |entry| entry[:path] }
          )
        end
      end
      # rubocop:enable Metrics/MethodLength

      # rubocop:disable Metrics/MethodLength
      def doctor_check(category:, status:, headline:, messages: [])
        ::Rails::Worktrees::ProjectMaintenance::Check.new(
          identifier: nil,
          category: category,
          status: status,
          headline: headline,
          messages: messages,
          relative_path: nil,
          updated_content: nil,
          make_executable: false,
          apply_messages: []
        )
      end
      # rubocop:enable Metrics/MethodLength

      # rubocop:disable Metrics/AbcSize
      def apply_maintenance_check(check, current_root:)
        if dry_run?
          info("Would update #{check.relative_path}")
          Array(check.apply_messages).each { |message| info(message) }
          return
        end

        path = maintenance_destination_path(check.relative_path, current_root)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, check.updated_content)
        FileUtils.chmod(0o755, path) if check.make_executable

        Array(check.apply_messages).each { |message| info(message) }
      end

      def maintenance_destination_path(relative_path, current_root)
        root_path = File.realpath(current_root)
        path = File.expand_path(relative_path, root_path)
        assert_within_root!(path, root_path, "Refusing to write outside of repository root: #{path}")
        parent_path = nearest_existing_parent(File.dirname(path))
        assert_parent_within_root!(parent_path, root_path, path)
        assert_not_symlink!(path)
        path
      end

      def assert_within_root!(path, root_path, message)
        raise Error, message unless within_root?(path, root_path)
      end

      def assert_parent_within_root!(parent_path, root_path, path)
        assert_within_root!(
          parent_path,
          root_path,
          "Refusing to write through symlinked directory outside repository root: #{path}"
        )
      end

      def assert_not_symlink!(path)
        raise Error, "Refusing to overwrite symlinked path: #{path}" if File.symlink?(path)
      end

      def within_root?(path, root_path)
        path == root_path || path.start_with?("#{root_path}#{File::SEPARATOR}")
      end

      def nearest_existing_parent(path)
        candidate = path
        until File.exist?(candidate)
          parent = File.dirname(candidate)
          return candidate if parent == candidate

          candidate = parent
        end

        File.realpath(candidate)
      end
      # rubocop:enable Metrics/AbcSize

      # rubocop:disable Metrics/MethodLength
      def complete_update(updated_count:, identical_count:, skipped_count:)
        if dry_run?
          success('Dry run complete')
          info("Would update #{updated_count} file#{'s' unless updated_count == 1}.")
          info('No changes were made.')
          return 0
        end

        success('Update complete')
        info(
          [
            "updated: #{updated_count}",
            "already up to date: #{identical_count}",
            "skipped: #{skipped_count}"
          ].join(', ')
        )
        0
      end
      # rubocop:enable Metrics/MethodLength
    end
    # rubocop:enable Metrics/ClassLength
  end
end
