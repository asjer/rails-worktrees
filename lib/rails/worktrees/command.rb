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
        @dry_run = @argv.first == '--dry-run'
        @argv.shift if dry_run?
      end

      def run
        return usage_error if dry_run? && @argv.first&.start_with?('-')

        meta_command_result = handle_meta_command
        return meta_command_result unless meta_command_result.nil?
        return usage_error if @argv.length > 1

        execute_worktree_command
      rescue Error => e
        @stderr.puts("Error: #{e.message}")
        1
      end

      private

      def dry_run? = @dry_run

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

      def resolve_worktree_context(explicit_worktree_name: nil)
        repo_root = git_capture('rev-parse', '--show-toplevel').strip
        project_name = File.basename(repo_root)
        workspaces = resolve_workspaces(repo_root, project_name)
        worktree_name = resolved_worktree_name(project_name, workspaces, explicit_worktree_name)

        { project_name: project_name, workspaces_root: workspaces[:root], worktree_name: worktree_name,
          uses_default_workspace_root: workspaces[:uses_default_root],
          branch_name: branch_name_for(worktree_name),
          target_dir: target_dir_for(project_name, worktree_name, workspaces) }
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

        if registered_worktree_path?(target_dir)
          remove_registered_worktree(target_dir)
        else
          FileUtils.rm_rf(target_dir)
        end
      end

      def branch_name_for(worktree_name)
        "#{@configuration.branch_prefix}/#{worktree_name}"
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
