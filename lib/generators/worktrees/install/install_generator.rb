require 'open3'
require 'rails/generators'

require_relative '../../rails/worktrees/mise_follow_up'
require_relative '../../rails/worktrees/puma_follow_up'
require_relative '../../../rails/worktrees/database_config_updater'
require_relative '../../../rails/worktrees/procfile_updater'
require_relative '../../../rails/worktrees/mise_toml_updater'
require_relative '../../../rails/worktrees/puma_config_updater'

module Worktrees
  module Generators
    # Installs the wt wrapper, configuration, and safe database.yml updates.
    # rubocop:disable Metrics/ClassLength
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Worktrees::Generators::MiseFollowUp
      include ::Rails::Worktrees::Generators::PumaFollowUp

      namespace 'worktrees:install'
      desc 'Installs bin/wt, a Rails::Worktrees initializer, and updates config/database.yml when safe.'
      source_root File.expand_path('../../rails/worktrees/templates', __dir__)
      class_option :conductor, type: :boolean, default: false,
                               desc: 'Configure the installer for ~/Sites/conductor/workspaces'
      class_option :yolo, type: :boolean, default: false,
                          desc: 'Apply common Procfile.dev, config/puma.rb, and mise .env follow-up edits when safe'

      FOLLOW_UP_TEMPLATE = <<~TEXT.freeze
          ============================================
            rails-worktrees installed successfully! 🚂

            Installed:
        %<installed>s

            Get started:
              $ bin/wt
              $ bin/wt my-feature

            Configure:
              config/initializers/rails_worktrees.rb
        %<notes>s
          ============================================
      TEXT

      def create_bin_wrapper
        template('bin/wt', 'bin/wt')
        chmod('bin/wt', 0o755)
      end

      def create_initializer
        template('rails_worktrees.rb.tt', 'config/initializers/rails_worktrees.rb')
      end

      def create_procfile_worktree_example
        return if options[:yolo]

        template('Procfile.dev.worktree.example.tt', 'Procfile.dev.worktree.example')
      end

      def apply_yolo_follow_ups
        return unless options[:yolo]

        update_procfile
        update_puma_config
        update_mise_toml
      end

      def update_database_configuration
        unless File.exist?(database_config_path)
          say_status(:skip, 'config/database.yml not found', :yellow)
          @database_outcome = :not_found
          return
        end

        result = database_update_result
        @database_outcome = result.changed? ? :updated : :identical
        announce_database_update(result)
      end

      def verify_installation
        if git_repo?
          say_status(:ok, 'git repository detected', :green)
        else
          say_status(:warning, 'run inside a git repository for bin/wt to work', :yellow)
        end
      end

      def show_follow_up
        say(follow_up_message)
      end

      private

      def database_config_path
        File.join(destination_root, 'config/database.yml')
      end

      def procfile_path
        File.join(destination_root, 'Procfile.dev')
      end

      def puma_config_path
        File.join(destination_root, 'config/puma.rb')
      end

      def mise_toml_paths
        [
          File.join(destination_root, 'mise.toml'),
          File.join(destination_root, '.mise.toml')
        ]
      end

      def database_update_result
        result = ::Rails::Worktrees::DatabaseConfigUpdater.new(
          content: File.read(database_config_path)
        ).call

        File.write(database_config_path, result.content) if result.changed?

        result
      end

      def follow_up_message
        "\n#{format(FOLLOW_UP_TEMPLATE, installed: installed_items_text, notes: follow_up_notes_text)}"
      end

      def follow_up_notes_text
        [super, puma_follow_up_notes_text].join
      end

      def installed_items_text
        items = [
          '      • bin/wt',
          '      • config/initializers/rails_worktrees.rb'
        ]
        items << '      • Procfile.dev.worktree.example' unless options[:yolo]
        items << database_follow_up_line if database_follow_up_line
        items.join("\n")
      end

      def database_follow_up_line
        case @database_outcome
        when :updated
          '      • config/database.yml (updated with WORKTREE_DATABASE_SUFFIX)'
        when :not_found
          '      • config/database.yml was not found — see README for manual setup'
        end
      end

      def announce_database_update(result)
        status = result.changed? ? :update : :identical
        color = result.changed? ? :green : :blue

        say_status(status, 'config/database.yml', color)
        result.messages.each { |message| say(message) }
      end

      def update_procfile
        unless File.exist?(procfile_path)
          say_status(:skip, 'Procfile.dev not found', :yellow)
          say('Skipped Procfile.dev yolo update because the file does not exist yet.')
          return
        end

        result = ::Rails::Worktrees::ProcfileUpdater.new(content: File.read(procfile_path)).call
        File.write(procfile_path, result.content) if result.changed?
        announce_updater_result('Procfile.dev', result)
      end

      def update_puma_config
        unless File.exist?(puma_config_path)
          say_status(:skip, 'config/puma.rb not found', :yellow)
          say('Skipped config/puma.rb yolo update because the file does not exist yet.')
          return
        end

        result = ::Rails::Worktrees::PumaConfigUpdater.new(content: File.read(puma_config_path)).call
        File.write(puma_config_path, result.content) if result.changed?
        announce_updater_result('config/puma.rb', result)
      end

      def update_mise_toml
        path = first_mise_toml_path
        return announce_missing_mise_toml unless path

        result = ::Rails::Worktrees::MiseTomlUpdater.new(
          content: File.read(path),
          file_name: File.basename(path)
        ).call

        File.write(path, result.content) if result.changed?
        announce_updater_result(File.basename(path), result)
      end

      def announce_updater_result(path, result)
        status, color = case result.status
                        when :updated then %i[update green]
                        when :identical then %i[identical blue]
                        else %i[skip yellow]
                        end

        say_status(status, path, color)
        result.messages.each { |message| say(message) }
      end

      def first_mise_toml_path
        mise_toml_paths.find { |candidate| File.file?(candidate) }
      end

      def announce_missing_mise_toml
        say_status(:skip, 'mise.toml/.mise.toml not found', :yellow)
        say('Skipped mise yolo update because no supported mise config file was found.')
      end

      def git_repo?
        _stdout_str, _stderr_str, status = Open3.capture3(
          'git', 'rev-parse', '--is-inside-work-tree', chdir: destination_root
        )
        status.success?
      rescue Errno::ENOENT
        false
      end

      def conductor_workspace_root
        "File.expand_path('~/Sites/conductor/workspaces')"
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
