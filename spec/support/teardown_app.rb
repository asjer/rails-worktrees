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
      module ActiveRecord
        Config = Struct.new(:env_name, :name, :database, :configuration_hash)
        class Base
          def self.configurations = self
          def self.configs_for(env_name:, **)
            JSON.parse(File.read('databases.json')).fetch(env_name, []).map.with_index do |database, index|
              Config.new(env_name, index.to_s, database, { database: database })
            end
          end
        end
        module Tasks
          module DatabaseTasks
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
