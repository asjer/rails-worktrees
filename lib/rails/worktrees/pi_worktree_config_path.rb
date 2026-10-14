module Rails
  module Worktrees
    # Decides whether .pi/worktree.json under an app root can be safely read and written in place.
    class PiWorktreeConfigPath
      RELATIVE_PATH = '.pi/worktree.json'.freeze

      def self.conflict(root)
        new(root).conflict
      end

      def initialize(root)
        @root = root
        @path = File.join(root, RELATIVE_PATH)
        @parent = File.dirname(@path)
      end

      # Returns why the config path is unsafe, or nil when it can be used.
      def conflict
        return 'is a symlink' if File.symlink?(@path)
        return 'is not a regular file' if File.exist?(@path) && !File.file?(@path)
        return "cannot be created because #{File.basename(@parent)} is not a directory" if parent_not_directory?
        return if within_root?(nearest_existing_realpath(@parent))

        'resolves outside the app through a symlinked directory'
      end

      private

      def parent_not_directory?
        (File.exist?(@parent) || File.symlink?(@parent)) && !File.directory?(@parent)
      end

      def nearest_existing_realpath(path)
        path = File.dirname(path) until File.exist?(path)
        File.realpath(path)
      end

      def within_root?(path)
        root = File.realpath(@root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end
    end
  end
end
