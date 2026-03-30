module Rails
  module Worktrees
    class Command
      # User-facing output, prompts, and help text.
      module Output
        private

        def handle_meta_command
          case @argv.first
          when '-h', '--help'
            @stdout.print(usage)
            0
          when '-v', '--version'
            @stdout.puts("wt #{Rails::Worktrees::VERSION}")
            0
          when '--env', '--print-env'
            preview_worktree_environment_command
          end
        end

        def usage_error
          @stderr.print(usage)
          1
        end

        def usage
          <<~USAGE
            wt #{::Rails::Worktrees::VERSION}
            Create Git worktrees for the current repository.

            Usage: wt [worktree-name]
                   wt --dry-run [worktree-name]
                   wt --print-env <worktree-name>

            Options:
              -h, --help                  Show this help message
              -v, --version               Show the script version
              --dry-run [name]            Preview the full worktree setup without changing anything
              --env, --print-env <name>   Preview DEV_PORT and WORKTREE_DATABASE_SUFFIX

            Quick start:
              wt                 Auto-pick a name from a bundled *.txt list
              wt my-feature      Use an explicit worktree name
              wt --dry-run my-feature
              wt --print-env my-feature

            How it works:
              - by default creates worktrees beside the repo in ../<project>.worktrees/<name>
              - when workspace_root or WT_WORKSPACES_ROOT is set, creates worktrees in <root>/<project>/<name>
              - always uses the branch name #{@configuration.branch_prefix}/<name>
              - bases new branches on the repository's origin default branch
              - auto-discovers bundled *.txt files from #{@configuration.name_sources_path}
              - retires bundled names in #{@configuration.used_names_file}
          USAGE
        end

        def confirm_or_abort!(prompt)
          if dry_run?
            info("Would confirm: #{prompt}")
            return
          end

          raise Error, 'Aborted.' unless confirm?(prompt)
        end

        def confirm?(prompt)
          return false unless @stdin.respond_to?(:tty?) && @stdin.tty?

          @stdout.print("#{prompt} [y/N] ")
          response = @stdin.gets.to_s.strip
          response.match?(/\A(?:y|yes)\z/i)
        end

        def info(message)
          @stdout.puts("→ #{message}")
        end

        def announce_dry_run = info('Dry run: previewing worktree setup without making changes')

        def complete_dry_run(context, env_values:)
          success('Dry run complete')
          print_context_summary(context, env_values: env_values)
          info('No changes were made.')
          0
        end

        def complete_reuse_dry_run(context, target:, branch:)
          preview_result = preview_worktree_environment(context)
          info("Would reuse existing worktree at '#{target}' on '#{branch}'")
          complete_dry_run(context, env_values: preview_result&.values)
        end

        def warning(message)
          @stderr.puts("⚠️  #{message}")
        end

        def success(message)
          @stdout.puts("✅ #{message}")
        end

        def print_env_preview(values)
          values.each { |key, value| @stdout.puts("#{key}=#{value}") }
        end

        def print_context_summary(context, target_dir: context[:target_dir], branch_name: context[:branch_name],
                                  env_values: nil)
          print_worktree_summary(
            target_dir,
            branch_name,
            context[:workspaces_root],
            uses_default_workspace_root: context[:uses_default_workspace_root],
            env_values: env_values
          )
        end

        def print_worktree_summary(target_dir, branch_name, workspaces_root, uses_default_workspace_root:, env_values:)
          @stdout.puts("Root:   #{workspaces_root}") unless uses_default_workspace_root
          @stdout.puts("Path:   #{target_dir}")
          @stdout.puts("Branch: #{branch_name}")
          @stdout.puts("Port:   #{env_values['DEV_PORT']}") if env_values && env_values['DEV_PORT']
          suffix = env_values && env_values['WORKTREE_DATABASE_SUFFIX']
          return unless suffix

          @stdout.puts("Suffix: #{suffix}")
        end
      end
    end
  end
end
