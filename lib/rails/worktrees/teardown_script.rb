# Executed by the target app's Rails runner (development bundle only).
# Keep validation and deletion in one process so the checked configs are the dropped configs.
module Rails
  module Worktrees
    # Validates the complete Rails database plan before applying any destructive effects.
    class DatabaseTeardown
      class SafetyError < StandardError; end

      def call(dry_run: false)
        suffix = ENV.fetch('WORKTREE_DATABASE_SUFFIX', '')
        raise SafetyError, 'WORKTREE_DATABASE_SUFFIX must not be empty; refusing teardown.' if suffix.strip.empty?

        databases = database_configs
        validate_databases!(databases, suffix)
        stop_overmind(dry_run: dry_run)
        databases.each do |config|
          puts "#{dry_run ? 'Would drop' : 'Dropping'} database '#{config.database}' " \
               "(#{config.env_name}/#{config.name})"
          ActiveRecord::Tasks::DatabaseTasks.drop(config) unless dry_run
        end
      end

      private

      def database_configs
        unless defined?(ActiveRecord::Base)
          raise SafetyError, 'ActiveRecord is required to inspect development/test databases.'
        end

        %w[development test].flat_map do |environment|
          configs = ActiveRecord::Base.configurations.configs_for(env_name: environment)
          raise SafetyError, "No database configurations found for #{environment}; refusing teardown." if configs.empty?

          configs
        end
      end

      def validate_databases!(databases, suffix)
        databases.each do |config|
          # A suffix in a SQLite directory does not protect an unsuffixed database file.
          next if File.basename(config.database.to_s).include?(suffix)

          raise SafetyError,
                "Database '#{config.database}' (#{config.env_name}/#{config.name}) does not contain " \
                "WORKTREE_DATABASE_SUFFIX '#{suffix}'; refusing teardown."
        end
      end

      def stop_overmind(dry_run:)
        return unless File.exist?('.overmind.sock')

        puts "#{dry_run ? 'Would stop' : 'Stopping'} Overmind at #{File.expand_path('.overmind.sock')}"
        return if dry_run
        return if system('overmind', 'quit', '--socket', '.overmind.sock')

        raise SafetyError, 'Could not stop Overmind; databases were kept.'
      end
    end
  end
end

begin
  Rails::Worktrees::DatabaseTeardown.new.call(dry_run: ARGV.include?('--dry-run'))
rescue StandardError => e
  warn "Teardown failed: #{e.message}"
  exit 1
end
