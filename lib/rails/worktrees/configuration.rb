module Rails
  module Worktrees
    # Stores application-level settings for the wt command.
    class Configuration
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
                    :worktree_database_suffix_max_length

      def initialize
        @bootstrap_env = DEFAULT_BOOTSTRAP_ENV
        @workspace_root = nil
        @branch_prefix = DEFAULT_BRANCH_PREFIX
        @dev_port_range = DEFAULT_DEV_PORT_RANGE
        @name_sources_path = DEFAULT_NAME_SOURCES_PATH
        @used_names_file = DEFAULT_USED_NAMES_FILE
        @worktree_database_suffix_max_length = DEFAULT_WORKTREE_DATABASE_SUFFIX_MAX_LENGTH
        @legacy_used_names_files = default_legacy_used_names_files
      end

      private

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
