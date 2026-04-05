module Rails
  module Worktrees
    class Command
      # Env bootstrap helpers and preview output.
      module EnvironmentSupport
        private

        def preview_worktree_environment_command
          raise Error, 'Usage: wt --print-env <worktree-name>' unless @argv.length == 2

          require_git_repo
          context = resolve_worktree_context(explicit_worktree_name: @argv[1])
          result = env_bootstrapper_for(context).preview

          print_env_preview(result.values)
          0
        end

        def env_bootstrapper_for(context)
          EnvBootstrapper.new(
            target_dir: context[:target_dir],
            worktree_name: context[:worktree_name],
            peer_roots: context.fetch(:peer_roots) { peer_roots_excluding(context[:target_dir]) },
            configuration: @configuration
          )
        end

        def bootstrap_worktree_environment(context)
          result = env_bootstrapper_for(context).call(dry_run: dry_run?)

          result.messages.each { |message| info(message) }
          result
        rescue StandardError => e
          warning("Could not bootstrap #{context[:target_dir]}/.env: #{e.message}")
        end

        def preview_worktree_environment(context)
          env_bootstrapper_for(context).preview
        rescue StandardError => e
          warning("Could not inspect #{context[:target_dir]}/.env: #{e.message}")
          nil
        end
      end
    end
  end
end
