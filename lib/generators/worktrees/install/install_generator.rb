require 'open3'
require 'rails/generators'

require_relative '../../rails/worktrees/mise_follow_up'
require_relative '../../../rails/worktrees/database_config_updater'

module Worktrees
  module Generators
    # Installs the wt wrapper, configuration, and safe database.yml updates.
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Worktrees::Generators::MiseFollowUp

      namespace 'worktrees:install'
      desc 'Installs bin/wt, a Rails::Worktrees initializer, and updates config/database.yml when safe.'
      source_root File.expand_path('../../rails/worktrees/templates', __dir__)
      class_option :conductor, type: :boolean, default: false,
                               desc: 'Configure the installer for ~/Sites/conductor/workspaces'

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
        template('Procfile.dev.worktree.example.tt', 'Procfile.dev.worktree.example')
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

      def installed_items_text
        items = [
          '      • bin/wt',
          '      • config/initializers/rails_worktrees.rb',
          '      • Procfile.dev.worktree.example'
        ]
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
  end
end
