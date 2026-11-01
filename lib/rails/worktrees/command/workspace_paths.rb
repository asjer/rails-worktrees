module Rails
  module Worktrees
    class Command
      # Resolves the sibling (default), workspace_root and in-repo worktrees_dir path layouts.
      module WorkspacePaths
        INVALID_WORKTREES_DIR_MESSAGE =
          "worktrees_dir must be a relative path inside the repository, like '.worktrees' (got %p).".freeze

        private

        def resolve_repository_context
          current_root = canonical_path(git_capture('rev-parse', '--show-toplevel').strip)
          common_dir = expand_git_path(git_capture('rev-parse', '--git-common-dir').strip, base_dir: @cwd)
          primary_root = primary_checkout_root_for(current_root, common_dir)

          repository_context_for(current_root, primary_root)
        end

        def resolve_repository_context_for(path)
          expanded_path = File.expand_path(path, @cwd)
          current_root = canonical_path(git_capture('-C', expanded_path, 'rev-parse', '--show-toplevel').strip)
          common_dir = expand_git_path(
            git_capture('-C', expanded_path, 'rev-parse', '--git-common-dir').strip,
            base_dir: expanded_path
          )
          primary_root = primary_checkout_root_for(current_root, common_dir)

          repository_context_for(current_root, primary_root)
        end

        def repository_context_for(current_root, primary_root)
          project_name = File.basename(primary_root)
          workspaces = resolve_workspaces(primary_root, project_name)

          {
            current_root: current_root,
            primary_root: primary_root,
            project_name: project_name,
            workspaces: workspaces,
            workspaces_root: workspaces[:root],
            uses_default_workspace_root: workspaces[:uses_default_root]
          }
        end

        def resolve_workspaces(repo_root, project_name)
          explicit_root = configured_workspaces_root
          return { root: explicit_root, layout: :workspace_root, uses_default_root: false } if explicit_root

          in_repo_dir = configured_worktrees_dir
          if in_repo_dir
            return { root: File.join(repo_root, in_repo_dir), layout: :in_repo, relative_dir: in_repo_dir,
                     uses_default_root: false }
          end

          { root: File.join(File.dirname(repo_root), "#{project_name}.worktrees"), layout: :sibling,
            uses_default_root: true }
        end

        def configured_workspaces_root
          env_root = @env['WT_WORKSPACES_ROOT']
          return expand_home(env_root) if present_path?(env_root)

          config_root = @configuration.workspace_root
          return unless present_path?(config_root)

          if present_path?(@configuration.worktrees_dir)
            raise Error, 'Set either workspace_root or worktrees_dir, not both.'
          end

          expand_home(config_root)
        end

        def configured_worktrees_dir
          value = @configuration.worktrees_dir
          return unless present_path?(value)

          normalized = Pathname(value.to_s).cleanpath
          raise Error, format(INVALID_WORKTREES_DIR_MESSAGE, value) unless valid_worktrees_dir?(normalized)

          normalized.to_s
        end

        def valid_worktrees_dir?(path)
          first_component = path.each_filename.first

          path.relative? && !path.to_s.start_with?('~') &&
            !path.each_filename.include?('..') && !['.', '.git'].include?(first_component)
        end

        def target_dir_for(project_name, worktree_name, workspaces)
          if workspaces[:layout] == :workspace_root
            File.join(workspaces[:root], project_name, worktree_name)
          else
            File.join(workspaces[:root], worktree_name)
          end
        end

        def prepare_target_parent(target_dir)
          parent_dir = File.dirname(target_dir)
          return if File.directory?(parent_dir)
          return info("Would create workspace directory '#{parent_dir}'") if dry_run?

          FileUtils.mkdir_p(parent_dir)
        end

        def primary_checkout_root_for(current_root, common_dir)
          return current_root unless File.basename(common_dir) == '.git'

          canonical_path(File.dirname(common_dir))
        end

        def expand_git_path(path, base_dir: @cwd)
          return path if path.start_with?('/')

          File.expand_path(path, base_dir)
        end

        def present_path?(path)
          !path.nil? && !path.to_s.empty?
        end

        def expand_home(path)
          case path
          when '~'
            Dir.home
          when %r{\A~/}
            File.join(Dir.home, path.delete_prefix('~/'))
          else
            path
          end
        end
      end
    end
  end
end
