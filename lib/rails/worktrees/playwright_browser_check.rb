require 'json'
require 'open3'

module Rails
  module Worktrees
    # Decides whether a worktree needs the Playwright Chromium build that matches
    # the playwright package pinned in its package.json.
    class PlaywrightBrowserCheck
      PACKAGES = %w[playwright @playwright/test].freeze
      DEPENDENCY_SECTIONS = %w[dependencies devDependencies].freeze
      CLI_PATH = 'node_modules/.bin/playwright'.freeze
      BROWSER = 'chromium'.freeze
      INSTALL_LOCATION = /^\s*Install location:\s*(.+?)\s*$/
      # Playwright writes this marker once a browser download has been fully extracted.
      INSTALLATION_MARKER = 'INSTALLATION_COMPLETE'.freeze

      def initialize(target_dir:, env:)
        @target_dir = target_dir
        @env = env
      end

      def applicable?
        package = JSON.parse(File.read(File.join(@target_dir, 'package.json')))
        DEPENDENCY_SECTIONS.any? do |section|
          dependencies = package[section]
          dependencies.is_a?(Hash) && PACKAGES.any? { |name| dependencies.key?(name) }
        end
      rescue Errno::ENOENT, JSON::ParserError
        false
      end

      # Returns false whenever the installed state cannot be proven; Playwright's own
      # installer then skips browsers that are already complete.
      def installed?
        locations = install_locations
        !locations.empty? && locations.all? { |location| File.file?(File.join(location, INSTALLATION_MARKER)) }
      end

      private

      def install_locations
        return [] unless File.exist?(File.join(@target_dir, CLI_PATH))

        output, status = Open3.capture2e(@env, CLI_PATH, 'install', '--dry-run', BROWSER, chdir: @target_dir)
        return [] unless status.success?

        output.scan(INSTALL_LOCATION).flatten
      rescue SystemCallError
        []
      end
    end
  end
end
