module Rails
  module Worktrees
    class Command
      # User-facing output, prompts, and help text.
      # rubocop:disable Metrics/ModuleLength
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
            Create and clean up Git worktrees for the current repository.

            Usage: wt [worktree-name]
                   wt [--skip-setup] [worktree-name]
                   wt --dry-run [worktree-name]
                   wt --print-env <worktree-name>
                   wt doctor
                   wt setup [--dry-run] [path|name]
                   wt update [--dry-run]
                   wt remove [--dry-run] [--force] <worktree-name>
                   wt delete [--dry-run] [--force] <worktree-name>
                   wt prune [--dry-run]

            Options:
              -h, --help                  Show this help message
              -v, --version               Show the script version
              --dry-run [name]            Preview worktree creation or cleanup without changing anything
              --skip-setup               Create the worktree without running setup steps
              --force                     Delete an unmerged local branch with wt remove/delete
              --env, --print-env <name>   Preview DEV_PORT and WORKTREE_DATABASE_SUFFIX

            Quick start:
              wt                 Auto-pick a name from a bundled *.txt list
              wt my-feature      Use an explicit worktree name
              wt --dry-run my-feature
              wt --skip-setup my-feature
              wt --print-env my-feature
              wt doctor
              wt setup
              wt setup my-feature
              wt setup ../my-project.worktrees/my-feature
              wt update --dry-run
              wt remove my-feature
              wt remove --force my-feature
              wt prune

            How it works:
              - by default creates worktrees beside the repo in ../<project>.worktrees/<name>
              - when workspace_root or WT_WORKSPACES_ROOT is set, creates worktrees in <root>/<project>/<name>
              - always uses the branch name #{@configuration.branch_prefix}/<name>
              - bases new branches on the repository's origin default branch
              - by default wt <name> both creates the worktree and runs setup automatically
              - wt setup reruns setup for the current checkout, a managed worktree name, or a specific checkout path, including manually-created worktrees
              - wt doctor audits install/config drift plus basic worktree health without changing files
              - wt update applies safe file-based fixes for managed installer artifacts and config hints
              - wt remove/delete can run from the main checkout or any sibling worktree, but never remove the worktree you're currently in
              - wt prune removes merged worktrees created by wt while skipping the main checkout and the checkout you're in
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

        def announce_dry_run = info('Dry run: previewing worktree changes without applying them')

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

        def complete_remove_dry_run(context, worktree_exists:, branch_exists:)
          info(remove_dry_run_target_message(context, worktree_exists: worktree_exists))
          info(remove_dry_run_branch_message(context, branch_exists: branch_exists))

          success('Dry run complete')
          print_context_summary(context, env_values: nil)
          info('No changes were made.')
          0
        end

        def remove_dry_run_target_message(context, worktree_exists:)
          return "Would skip worktree removal because '#{context[:target_dir]}' does not exist" unless worktree_exists

          action = if registered_worktree_path?(context[:target_dir])
                     'remove registered worktree at'
                   else
                     'remove existing target path'
                   end
          "Would #{action} '#{context[:target_dir]}'"
        end

        def remove_dry_run_branch_message(context, branch_exists:)
          unless branch_exists
            return "Would skip local branch deletion because '#{context[:branch_name]}' does not exist"
          end

          "Would delete local branch '#{context[:branch_name]}'"
        end

        def print_prune_candidates(candidates)
          candidates.each do |context|
            info("#{context[:worktree_name]} => #{context[:target_dir]} (#{context[:branch_name]})")
          end
        end

        def complete_prune_noop
          info('No merged worktrees created by wt are ready to prune.')
          0
        end

        def complete_prune_dry_run(candidates)
          info("Would prune #{candidates.length} merged worktree#{'s' unless candidates.length == 1}")
          success('Dry run complete')
          info('No changes were made.')
          0
        end

        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        def print_doctor_report(checks)
          checks.each do |check|
            printer = check.ok? ? :info : :warning
            send(printer, "#{check.category}: #{check.headline}")
            Array(check.messages).each { |message| info(message) }
          end

          fixable_count = checks.count(&:fixable?)
          warning_count = checks.count(&:warning?)

          if fixable_count.zero? && warning_count.zero?
            success('Doctor found no issues.')
          else
            warning(
              "Doctor found #{fixable_count} fixable issue#{'s' unless fixable_count == 1} and " \
              "#{warning_count} warning#{'s' unless warning_count == 1}."
            )
            info('Run `wt update --dry-run` to preview safe fixes.') if fixable_count.positive?
          end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

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
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
