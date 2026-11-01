require 'fileutils'

module Rails
  module Worktrees
    class Command
      # Keeps an in-repo worktrees_dir out of the main checkout's untracked files.
      module InRepoWorktrees
        private

        def in_repo_layout?(workspaces) = workspaces[:layout] == :in_repo

        def ensure_worktrees_dir_ignored(context)
          workspaces = context[:workspaces]
          return unless in_repo_layout?(workspaces)
          return if worktrees_dir_ignored?(context[:primary_root], workspaces)

          entry = worktrees_dir_exclude_entry(workspaces)
          exclude_path = info_exclude_path(context[:primary_root])
          return info("Would add '#{entry}' to #{exclude_path}") if dry_run?

          append_exclude_entry(exclude_path, entry)
        end

        def worktrees_dir_ignored?(primary_root, workspaces)
          git_success?('-C', primary_root, 'check-ignore', '-q', "#{workspaces[:relative_dir]}/")
        end

        # Escapes gitignore metacharacters so the entry matches only the literal directory.
        def worktrees_dir_exclude_entry(workspaces)
          escaped = workspaces[:relative_dir]
                    .gsub(/[\\*?\[\]]/) { |char| "\\#{char}" }
                    .sub(/ +\z/) { |spaces| spaces.gsub(' ', '\ ') }
          "/#{escaped}/"
        end

        def info_exclude_path(primary_root)
          git_path = git_capture('-C', primary_root, 'rev-parse', '--git-path', 'info/exclude').strip
          expand_git_path(git_path, base_dir: primary_root)
        end

        def append_exclude_entry(exclude_path, entry)
          FileUtils.mkdir_p(File.dirname(exclude_path))
          separator = missing_trailing_newline?(exclude_path) ? "\n" : ''
          File.open(exclude_path, 'a') { |file| file.write("#{separator}#{entry}\n") }
          info("Added '#{entry}' to #{exclude_path} so the main checkout ignores in-repo worktrees")
        rescue SystemCallError => e
          warning(
            "Could not update #{exclude_path} (#{e.class}); add '#{entry}' to .gitignore " \
            'so the main checkout does not show the worktrees as untracked files.'
          )
        end

        def missing_trailing_newline?(path)
          File.file?(path) && !File.empty?(path) && !File.read(path).end_with?("\n")
        end

        def in_repo_worktrees_doctor_check(repository)
          workspaces = repository[:workspaces]
          return unless in_repo_layout?(workspaces)

          if worktrees_dir_ignored?(repository[:primary_root], workspaces)
            ignored_worktrees_dir_check(workspaces)
          else
            unignored_worktrees_dir_check(workspaces)
          end
        end

        def ignored_worktrees_dir_check(workspaces)
          doctor_check(category: :worktree, status: :ok,
                       headline: "In-repo worktrees directory #{workspaces[:root]} is ignored by Git.")
        end

        def unignored_worktrees_dir_check(workspaces)
          doctor_check(
            category: :worktree,
            status: :warning,
            headline: "In-repo worktrees directory #{workspaces[:root]} is not ignored by Git.",
            messages: ["Add '#{worktrees_dir_exclude_entry(workspaces)}' to .gitignore, " \
                       'or create a worktree with wt to add it to .git/info/exclude.']
          )
        end
      end
    end
  end
end
