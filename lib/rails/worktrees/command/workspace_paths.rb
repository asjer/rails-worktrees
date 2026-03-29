# frozen_string_literal: true

module Rails
  module Worktrees
    class Command
      # Resolves the default and explicit workspace path layouts.
      module WorkspacePaths
        private

        def resolve_workspaces(repo_root, project_name)
          explicit_root = configured_workspaces_root
          return { root: explicit_root, uses_default_root: false } if explicit_root

          { root: File.join(File.dirname(repo_root), "#{project_name}.worktrees"), uses_default_root: true }
        end

        def configured_workspaces_root
          env_root = @env['WT_WORKSPACES_ROOT']
          return expand_home(env_root) if present_path?(env_root)

          config_root = @configuration.workspace_root
          return expand_home(config_root) if present_path?(config_root)

          nil
        end

        def target_dir_for(project_name, worktree_name, workspaces)
          if workspaces[:uses_default_root]
            File.join(workspaces[:root], worktree_name)
          else
            File.join(workspaces[:root], project_name, worktree_name)
          end
        end

        def prepare_target_parent(target_dir)
          parent_dir = File.dirname(target_dir)
          return if File.directory?(parent_dir)
          return info("Would create workspace directory '#{parent_dir}'") if dry_run?

          FileUtils.mkdir_p(parent_dir)
        end

        def present_path?(path)
          !path.nil? && !path.empty?
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
