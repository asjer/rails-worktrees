module Rails
  module Worktrees
    # Stores application-level settings for the wt command.
    class Configuration
      CONFIGURABLE_ATTRIBUTES = %i[
        bootstrap_env
        workspace_root
        dev_port_range
        branch_prefix
        name_sources_path
        used_names_file
        worktree_database_suffix_max_length
        post_create_command
        run_bundle_install
        run_yarn_install
        run_db_prepare
        run_test_db_prepare
        run_test_assets_precompile
        link_credential_keys
        link_test_credential_key
        link_production_credential_key
      ].freeze

      DEFAULT_BOOTSTRAP_ENV = true
      DEFAULT_BRANCH_PREFIX = '🚂'.freeze
      DEFAULT_DEV_PORT_RANGE = (3000..3999)
      DEFAULT_USED_NAMES_DIRECTORY = File.join(
        ENV.fetch('XDG_STATE_HOME', File.join(Dir.home, '.local/state')),
        'rails-worktrees'
      )
      DEFAULT_USED_NAMES_FILE = File.join(DEFAULT_USED_NAMES_DIRECTORY, 'used-names.tsv')
      DEFAULT_NAME_SOURCES_PATH = File.expand_path('names', __dir__)
      DEFAULT_WORKTREE_DATABASE_SUFFIX_MAX_LENGTH = 18

      attr_accessor :bootstrap_env, :branch_prefix, :dev_port_range, :legacy_used_names_files,
                    :name_sources_path, :used_names_file, :workspace_root,
                    :worktree_database_suffix_max_length,
                    :post_create_command,
                    :run_bundle_install, :run_yarn_install,
                    :run_db_prepare, :run_test_db_prepare, :run_test_assets_precompile,
                    :link_credential_keys, :link_test_credential_key, :link_production_credential_key

      def initialize
        assign_core_defaults
        assign_post_create_defaults
      end

      private

      def assign_core_defaults
        @bootstrap_env = DEFAULT_BOOTSTRAP_ENV
        @workspace_root = nil
        @branch_prefix = DEFAULT_BRANCH_PREFIX
        @dev_port_range = DEFAULT_DEV_PORT_RANGE
        @name_sources_path = DEFAULT_NAME_SOURCES_PATH
        @used_names_file = DEFAULT_USED_NAMES_FILE
        @worktree_database_suffix_max_length = DEFAULT_WORKTREE_DATABASE_SUFFIX_MAX_LENGTH
        @legacy_used_names_files = default_legacy_used_names_files
      end

      def assign_post_create_defaults
        @post_create_command = nil
        @run_bundle_install = true
        @run_yarn_install = true
        @run_db_prepare = true
        @run_test_db_prepare = true
        @run_test_assets_precompile = true
        @link_credential_keys = true
        @link_test_credential_key = false
        @link_production_credential_key = false
      end

      def default_legacy_used_names_files
        state_home = ENV.fetch('XDG_STATE_HOME', File.join(Dir.home, '.local/state'))

        [
          File.join(state_home, 'wt', 'used-names.tsv'),
          File.join(state_home, 'wt', 'used-cities.tsv')
        ]
      end
    end
  end
end
