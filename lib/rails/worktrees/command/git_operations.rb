require 'open3'

module Rails
  module Worktrees
    class Command
      # Shell-level git helpers, branch/worktree queries, and worktree creation.
      module GitOperations
        private

        def require_git_repo
          return if git_success?('rev-parse', '--is-inside-work-tree')

          raise Error, 'Run wt from inside a Git repository.'
        end

        def resolve_default_branch
          unless git_success?('remote', 'get-url', 'origin')
            raise Error, "This repository does not have an 'origin' remote."
          end

          ref = git_capture('symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD', allow_failure: true).strip
          if ref.empty?
            raise Error,
                  "Could not resolve origin's default branch. Run 'git fetch origin' and " \
                  "'git remote set-head origin -a', then try again."
          end

          ref.delete_prefix('refs/remotes/origin/')
        end

        def branch_exists_locally?(branch_name)
          git_success?('show-ref', '--verify', '--quiet', "refs/heads/#{branch_name}")
        end

        def branch_exists_on_origin?(branch_name)
          git_success?('show-ref', '--verify', '--quiet', "refs/remotes/origin/#{branch_name}")
        end

        def branch_is_checked_out_elsewhere?(branch_name)
          worktree_branch_checked_out?(branch_name, worktree_list_output)
        end

        def registered_worktree_path?(target_dir)
          normalized_target = canonical_path(target_dir)

          worktree_list_output.each_line.any? do |line|
            next unless line.start_with?('worktree ')

            canonical_path(line.delete_prefix('worktree ').strip) == normalized_target
          end
        end

        def worktree_branch_checked_out?(branch_name, output)
          target_branch = "branch refs/heads/#{branch_name}"
          output.each_line.slice_after { |line| line.chomp.empty? }.any? do |lines|
            lines.first&.start_with?('worktree ') && lines.any? { |line| line.chomp == target_branch }
          end
        end

        def worktree_list_output = git_capture('worktree', 'list', '--porcelain')

        def canonical_path(path)
          File.realpath(path)
        rescue Errno::ENOENT then File.expand_path(path)
        end

        def create_new_branch_worktree(branch_name, target_dir)
          default_branch = resolve_default_branch
          if dry_run?
            info("Would create '#{branch_name}' from 'origin/#{default_branch}'")
            return
          end

          info("Creating '#{branch_name}' from 'origin/#{default_branch}'")
          git!('worktree', 'add', '-b', branch_name, target_dir, "origin/#{default_branch}")
        end

        def attach_existing_branch_worktree(branch_name, target_dir)
          if branch_is_checked_out_elsewhere?(branch_name)
            return attach_checked_out_branch_worktree(branch_name, target_dir)
          end

          info("#{dry_run? ? 'Would attach' : 'Attaching'} existing local branch '#{branch_name}'")
          return if dry_run?

          git!('worktree', 'add', target_dir, branch_name)
        end

        def track_remote_branch_worktree(branch_name, target_dir)
          if dry_run?
            info("Would create local tracking branch '#{branch_name}' from 'origin/#{branch_name}'")
            return
          end

          info("Creating local tracking branch '#{branch_name}' from 'origin/#{branch_name}'")
          git!('worktree', 'add', '--track', '-b', branch_name, target_dir, "origin/#{branch_name}")
        end

        def remove_registered_worktree(target_dir)
          info("Removing registered worktree at '#{target_dir}'")
          git!('worktree', 'remove', '--force', target_dir)
        end

        def git!(*)
          stdout_str, stderr_str, status = Open3.capture3(@env.to_h, 'git', *, chdir: @cwd)
          return stdout_str if status.success?

          raise Error, combined_output(stdout_str, stderr_str)
        end

        def git_capture(*, allow_failure: false)
          stdout_str, stderr_str, status = Open3.capture3(@env.to_h, 'git', *, chdir: @cwd)
          return stdout_str if status.success? || allow_failure

          raise Error, combined_output(stdout_str, stderr_str)
        end

        def git_success?(*)
          _stdout_str, _stderr_str, status = Open3.capture3(@env.to_h, 'git', *, chdir: @cwd)
          status.success?
        end

        def combined_output(stdout_str, stderr_str)
          output = [stdout_str, stderr_str].map(&:strip).reject(&:empty?).join("\n")
          return output unless output.empty?

          'git command failed'
        end

        def attach_checked_out_branch_worktree(branch_name, target_dir)
          confirm_or_abort!(
            "'#{branch_name}' is already checked out in another worktree. Create another checkout anyway?"
          )
          info("#{dry_run? ? 'Would create' : 'Creating'} another checkout for '#{branch_name}'")
          return if dry_run?

          git!('worktree', 'add', '--force', target_dir, branch_name)
        end
      end
    end
  end
end
