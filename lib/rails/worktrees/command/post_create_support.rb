module Rails
  module Worktrees
    class Command
      # Delegates post-create setup steps to PostCreateRunner.
      module PostCreateSupport
        private

        def run_post_create_steps(context, bootstrapped_env: nil)
          post_create_runner_for(context, bootstrapped_env: bootstrapped_env).call(dry_run: false)
        end

        def preview_post_create_steps(context, bootstrapped_env: nil)
          post_create_runner_for(context, bootstrapped_env: bootstrapped_env).call(dry_run: true)
        end

        def post_create_runner_for(context, bootstrapped_env: nil)
          PostCreateRunner.new(
            target_dir: context[:target_dir],
            peer_roots: context.fetch(:peer_roots) { peer_roots_excluding(context[:target_dir]) },
            configuration: @configuration,
            bootstrapped_env: bootstrapped_env,
            io: { stdout: @stdout, stderr: @stderr }
          )
        end

        def peer_roots_excluding(target_dir)
          worktree_entries
            .map { |entry| entry[:path] }
            .reject { |path| path == target_dir }
        end
      end
    end
  end
end
