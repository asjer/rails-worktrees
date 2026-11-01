require 'json'

# Executed by the target app's Rails runner, first in test, then in development.
module Rails
  module Worktrees
    # Validates the complete Rails database plan before applying any destructive effects.
    class DatabaseTeardown
      class SafetyError < StandardError; end

      def call(test_plan:, export: false, dry_run: false)
        suffix = ENV.fetch('WORKTREE_DATABASE_SUFFIX', '')
        raise SafetyError, 'WORKTREE_DATABASE_SUFFIX must not be empty; refusing teardown.' if suffix.strip.empty?

        return export_test_configs(test_plan, suffix) if export

        development = database_configs('development')
        databases = development + test_configs(test_plan, suffix)
        validate_databases!(databases, suffix)
        check_protection!(development)
        stop_overmind(dry_run: dry_run)
        drop_databases(databases, dry_run: dry_run)
      end

      private

      def database_configs(environment)
        unless defined?(ActiveRecord::Base)
          raise SafetyError, 'ActiveRecord is required to inspect development/test databases.'
        end

        configs = ActiveRecord::Base.configurations.configs_for(env_name: environment)
        raise SafetyError, "No database configurations found for #{environment}; refusing teardown." if configs.empty?

        configs
      end

      def export_test_configs(path, suffix)
        configs = database_configs('test')
        validate_databases!(configs, suffix)
        check_protection!(configs)
        File.write(path, JSON.generate('suffix' => suffix, 'configs' => config_hash(configs)))
      end

      def test_configs(path, suffix)
        plan = JSON.parse(File.read(path))
        if plan['suffix'] != suffix
          raise SafetyError,
                'Test environment changed WORKTREE_DATABASE_SUFFIX; refusing teardown.'
        end

        ActiveRecord::DatabaseConfigurations.new('test' => plan.fetch('configs')).configs_for(env_name: 'test')
      end

      def config_hash(configs)
        configs.to_h { |config| [config.name, config.configuration_hash] }
      end

      def check_protection!(databases)
        original = ActiveRecord::Base.configurations
        existing = existing_databases(databases)
        # Keep the resolved objects: rebuilding hashes would reapply environment URLs to explicit YAML URLs.
        ActiveRecord::Base.configurations = existing
        ENV.delete('DISABLE_DATABASE_ENVIRONMENT_CHECK')
        existing.map(&:env_name).uniq.each do |environment|
          ActiveRecord::Tasks::DatabaseTasks.check_protected_environments!(environment)
        end
      ensure
        ActiveRecord::Base.configurations = original if original
      end

      def existing_databases(databases)
        # SQLite opens would create absent files even in a dry-run. Absent files have no protected metadata.
        databases.reject { |config| config.adapter == 'sqlite3' && !File.exist?(config.database) }
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

      def drop_databases(databases, dry_run:)
        databases.each do |config|
          puts "#{dry_run ? 'Would drop' : 'Dropping'} database '#{config.database}' " \
               "(#{config.env_name}/#{config.name})"
          ActiveRecord::Tasks::DatabaseTasks.drop(config) unless dry_run
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
  export = ARGV.first == '--export-test-configs'
  Rails::Worktrees::DatabaseTeardown.new.call(test_plan: ARGV.fetch(1), export: export,
                                              dry_run: ARGV.include?('--dry-run'))
rescue StandardError => e
  warn "Teardown failed: #{e.message}"
  exit 1
end
