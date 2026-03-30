require 'open3'
require 'fileutils'

module Rails
  module Worktrees
    class Command
      # Shell-level git helpers, branch/worktree queries, and worktree creation.
      # rubocop:disable Metrics/ModuleLength
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

        def current_checkout_branch
          git_capture('branch', '--show-current', allow_failure: true).strip
        end

        def registered_worktree_path?(target_dir)
          normalized_target = canonical_path(target_dir)

          worktree_entries.any? { |entry| entry[:path] == normalized_target }
        end

        def worktree_entries_for_branch(branch_name)
          worktree_entries.select { |entry| entry[:branch_name] == branch_name }
        end

        def worktree_branch_checked_out?(branch_name, output)
          target_branch = "branch refs/heads/#{branch_name}"
          output.each_line.slice_after { |line| line.chomp.empty? }.any? do |lines|
            lines.first&.start_with?('worktree ') && lines.any? { |line| line.chomp == target_branch }
          end
        end

        def worktree_list_output = git_capture('worktree', 'list', '--porcelain')

        def worktree_entries
          worktree_list_output.split("\n\n").filter_map do |block|
            entry = parse_worktree_entry(block)
            entry[:path] ? entry : nil
          end
        end

        def parse_worktree_entry(block)
          entry = { branch_name: nil }

          block.each_line(chomp: true) do |line|
            case line
            when /\Aworktree /
              entry[:path] = canonical_path(line.delete_prefix('worktree '))
            when %r{\Abranch refs/heads/}
              entry[:branch_name] = line.delete_prefix('branch refs/heads/')
            end
          end

          entry
        end

        def canonical_path(path)
          File.realpath(path)
        rescue Errno::ENOENT then File.expand_path(path)
        end

        def branch_merged_into_default?(branch_name)
          default_branch = resolve_default_branch
          git_success?('merge-base', '--is-ancestor', branch_name, "origin/#{default_branch}")
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

        def remove_target_path(target_dir)
          if registered_worktree_path?(target_dir)
            remove_registered_worktree(target_dir)
          else
            info("Removing existing target path '#{target_dir}'")
            FileUtils.rm_rf(target_dir)
          end
        end

        def delete_local_branch(branch_name, force: false)
          ensure_local_branch_removable!(branch_name, force: force)

          info("Deleting local branch '#{branch_name}'")
          git!('branch', force ? '-D' : '-d', branch_name)
        end

        def ensure_local_branch_removable!(branch_name, force: false)
          return if force

          default_branch = resolve_default_branch
          return if branch_merged_into_default?(branch_name)

          raise Error,
                "Local branch '#{branch_name}' is not merged into origin/#{default_branch}. " \
                'Re-run with --force to delete it.'
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
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
