require 'fileutils'
require_relative 'command/environment_support'
require_relative 'command/git_operations'
require_relative 'command/name_picking'
require_relative 'command/output'
require_relative 'command/workspace_paths'

module Rails
  module Worktrees
    # Creates or attaches worktrees for the current repository.
    # rubocop:disable Metrics/ClassLength
    class Command
      REMOVE_SUBCOMMANDS = %w[remove delete].freeze

      include GitOperations
      include EnvironmentSupport
      include NamePicking
      include Output
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

      def extract_flags!
        @dry_run = extract_flag!('--dry-run')
        @force = extract_flag!('--force')
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

      def execute_requested_command
        return execute_remove_command if remove_subcommand?
        return execute_prune_command if prune_subcommand?
        return usage_error if @argv.length > 1 || force?

        execute_worktree_command
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

      def validate_prune_args!
        raise Error, 'Usage: wt prune' unless @argv.length == 1
        raise Error, 'The --force flag is only supported with wt remove.' if force?
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
        bootstrap_result = bootstrap_worktree_environment(context)
        return complete_dry_run(context, env_values: bootstrap_result&.values) if dry_run?

        success('Worktree ready')
        print_context_summary(context, env_values: bootstrap_result&.values)
        0
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
    end
    # rubocop:enable Metrics/ClassLength
  end
end
