require 'fileutils'
require 'json'
require 'rbconfig'

# A tiny Rails runner boundary: database operations and Overmind are recorded,
# while the real teardown script and CLI run in separate processes.
module TeardownApp
  def install_teardown_app(root, databases: nil)
    databases ||= {
      'development' => %w[app_development_feature_one app_development_feature_one_cache],
      'test' => %w[app_test_feature_one app_test_feature_one_queue],
      'production' => ['app_production']
    }
    FileUtils.mkdir_p(File.join(root, 'bin'))
    FileUtils.mkdir_p(File.join(root, 'config'))
    File.write(File.join(root, 'databases.json'), JSON.generate(databases))
    File.write(File.join(root, 'bin/rails'), <<~RUBY)
      #!#{RbConfig.ruby}
      abort 'Expected runner' unless ARGV.shift == 'runner'
      require_relative '../config/environment'
      load ARGV.shift
    RUBY
    FileUtils.chmod(0o755, File.join(root, 'bin/rails'))
    File.write(File.join(root, 'config/environment.rb'), teardown_environment)
  end

  def teardown_environment
    <<~'RUBY'
      require 'json'
      require 'uri'
      module ActiveRecord
        Config = Struct.new(:env_name, :name, :database, :configuration_hash) do
          def adapter = 'postgresql'
        end
        class DatabaseConfigurations
          def initialize(configs)
            @configs = configs
          end

          def configs_for(env_name:, **)
            entries = @configs.fetch(env_name, {})
            if entries.is_a?(Array)
              entries = entries.each_with_index.to_h { |database, index| [index.to_s, { 'database' => database }] }
            end
            entries.map do |name, attributes|
              database = attributes.fetch('database')
              Config.new(env_name, name, database, { 'database' => database })
            end
          end
        end
        class Base
          def self.configurations
            @configurations ||= begin
              path = "databases-#{ENV.fetch('RAILS_ENV')}.json"
              path = 'databases.json' unless File.exist?(path)
              configs = JSON.parse(File.read(path))
              if ENV['DATABASE_URL']
                configs[ENV.fetch('RAILS_ENV')][0] = URI(ENV['DATABASE_URL']).path.delete_prefix('/')
              end
              DatabaseConfigurations.new(configs)
            end
          end

          def self.configurations=(value)
            @configurations = value.is_a?(DatabaseConfigurations) ? value : DatabaseConfigurations.new(value)
          end
        end
        module Tasks
          module DatabaseTasks
            def self.check_protected_environments!(environment)
              return if ENV['DISABLE_DATABASE_ENVIRONMENT_CHECK']
              raise 'Database is protected: production' if File.exist?("protected-#{environment}")
            end

            def self.drop(config)
              abort 'simulated drop failure' if File.exist?('fail-drop')
              File.open('effects.log', 'a') { |file| file.puts("drop #{config.database}") }
            end
          end
        end
      end
    RUBY
  end

  def install_teardown_overmind(root, tool_dir)
    FileUtils.mkdir_p(tool_dir)
    File.write(File.join(root, '.overmind.sock'), '')
    File.write(File.join(tool_dir, 'overmind'), <<~BASH)
      #!/usr/bin/env bash
      printf 'overmind %s\n' "$*" >> effects.log
      [ ! -f fail-overmind ]
    BASH
    FileUtils.chmod(0o755, File.join(tool_dir, 'overmind'))
  end
end
