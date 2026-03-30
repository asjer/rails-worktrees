module Rails
  module Worktrees
    class Command
      # Auto-picking names from bundled .txt files and tracking retired names.
      # rubocop:disable Metrics/ModuleLength
      module NamePicking
        private

        def resolve_worktree_name(project_name, workspaces)
          worktree_name = @argv.first
          return validate_worktree_name(worktree_name) if worktree_name && !worktree_name.empty?

          source_file, auto_name = pick_random_source_name(project_name, workspaces)
          info("Selected #{name_source_label(source_file)} name '#{auto_name}'")
          auto_name
        end

        def pick_random_source_name(project_name, workspaces)
          eligible_sources = name_source_files.filter_map do |source_file|
            available_names = list_available_names(source_file, project_name, workspaces)
            next if available_names.empty?

            [source_file, available_names]
          end

          if eligible_sources.empty?
            raise Error, "No unused names are available in #{@configuration.name_sources_path}/*.txt"
          end

          selected_source, available_names = eligible_sources.sample
          [selected_source, available_names.sample]
        end

        def name_source_files
          path = @configuration.name_sources_path
          files = Dir.glob(File.join(path, '*.txt')).select { |file| File.file?(file) }
          raise Error, "No name list files found in #{path}" if files.empty?

          files
        end

        def name_source_label(source_file) = File.basename(source_file, '.txt')

        def list_available_names(source_file, project_name, workspaces)
          source_names(source_file).select do |candidate|
            valid_auto_name?(candidate) && available_for_auto_pick?(candidate, project_name, workspaces)
          end
        end

        def source_names(source_file)
          File.readlines(source_file, chomp: true).filter_map do |line|
            name = line.delete_suffix("\r").strip
            next if name.empty? || name.start_with?('#')

            name
          end
        end

        def available_for_auto_pick?(candidate, project_name, workspaces)
          branch_name = branch_name_for(candidate)
          target_dir = target_dir_for(project_name, candidate, workspaces)

          !name_is_retired?(candidate) &&
            !branch_exists_locally?(branch_name) &&
            !branch_exists_on_origin?(branch_name) &&
            !File.exist?(target_dir)
        end

        def name_exists_in_any_source?(candidate)
          name_source_files.any? { |f| source_names(f).include?(candidate) }
        end

        def name_is_retired?(candidate)
          state_file = retired_names_file
          return false unless state_file

          File.foreach(state_file).any? { |line| line.split("\t", 2).first == candidate }
        end

        def record_retired_name(worktree_name, project_name)
          return unless bundled_name_needs_retirement?(worktree_name)

          ensure_state_store
          timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
          File.open(@configuration.used_names_file, 'a') do |file|
            file.puts([worktree_name, project_name, timestamp].join("\t"))
          end
        end

        def ensure_state_store
          state_file = @configuration.used_names_file
          FileUtils.mkdir_p(File.dirname(state_file))
          return if File.exist?(state_file)

          legacy_path = Array(@configuration.legacy_used_names_files).find { |path| File.file?(path) }
          FileUtils.cp(legacy_path, state_file) if legacy_path
        end

        def bundled_name_needs_retirement?(worktree_name)
          name_exists_in_any_source?(worktree_name) && !name_is_retired?(worktree_name)
        end

        def settle_retired_name(worktree_name, project_name, dry_run: false)
          return record_retired_name(worktree_name, project_name) unless dry_run

          return unless bundled_name_needs_retirement?(worktree_name)

          info("Would retire bundled name '#{worktree_name}'")
        end

        def reject_retired_name_for_new_branch(worktree_name)
          return unless name_exists_in_any_source?(worktree_name)
          return unless name_is_retired?(worktree_name)

          raise Error,
                "Bundled name '#{worktree_name}' has already been used and retired. " \
                "Pick another name or run 'wt' with no argument for a fresh one."
        end

        def validate_worktree_name(worktree_name)
          raise Error, 'Worktree name is required.' if worktree_name.nil? || worktree_name.empty?
          raise Error, "Worktree name must not be '.' or '..'." if %w[. ..].include?(worktree_name)
          raise Error, "Worktree name must not contain '/'." if worktree_name.include?('/')
          raise Error, 'Worktree name must not contain spaces.' if worktree_name.match?(/\s/)
          unless git_valid_ref_name?(worktree_name)
            raise Error, "Worktree name '#{worktree_name}' is not a valid Git ref component."
          end

          worktree_name
        end

        def git_valid_ref_name?(name)
          git_success?('check-ref-format', '--branch', name)
        end

        def valid_auto_name?(worktree_name)
          validate_worktree_name(worktree_name)
          true
        rescue Error
          false
        end

        def retired_names_file
          if File.file?(@configuration.used_names_file)
            @configuration.used_names_file
          else
            Array(@configuration.legacy_used_names_files).find { |path| File.file?(path) }
          end
        end
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
