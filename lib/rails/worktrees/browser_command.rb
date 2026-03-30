require 'rbconfig'
require 'uri'

module Rails
  module Worktrees
    # Opens the current app/worktree in a browser using the local DEV_PORT.
    # rubocop:disable Metrics/ClassLength
    class BrowserCommand
      APP_ROOT_ENV_KEY = 'RAILS_WORKTREES_APP_ROOT'.freeze
      ENV_FILE_NAME = '.env'.freeze

      def initialize(argv:, io:, env:, cwd:, host_os: RbConfig::CONFIG['host_os'])
        @argv = argv.dup
        @stdin = io.fetch(:stdin)
        @stdout = io.fetch(:stdout)
        @stderr = io.fetch(:stderr)
        @env = env
        @cwd = cwd
        @host_os = host_os
      end

      def run
        meta_command_result = handle_meta_command
        return meta_command_result unless meta_command_result.nil?
        return usage_error if @argv.length > 1

        url = build_url(@argv.first)
        open_browser(url)
        @stdout.puts("🌐 Opening #{url}")
        0
      rescue Error => e
        @stderr.puts("Error: #{e.message}")
        1
      end

      private

      def handle_meta_command
        case @argv.first
        when '-h', '--help'
          @stdout.print(usage)
          0
        when '-v', '--version'
          @stdout.puts("ob #{Rails::Worktrees::VERSION}")
          0
        when '--url', '--print-url'
          print_url_command
        end
      end

      def usage_error
        @stderr.print(usage)
        1
      end

      def usage
        <<~USAGE
          ob #{::Rails::Worktrees::VERSION}
          Open the current app/worktree in your browser using DEV_PORT.

          Usage: ob [route]
                 ob --print-url [route]

          Options:
            -h, --help              Show this help message
            -v, --version           Show the script version
            --url, --print-url      Print the resolved URL without opening a browser

          Quick start:
            ob
            ob contact
            ob '/contact?ref=nav'
            ob --print-url '?from=nav'

          Route rules:
            - route is optional; the default is /
            - values like contact and admin/users become /contact and /admin/users
            - query-only values like ?from=nav resolve to /?from=nav
            - full URLs are rejected; ob only opens localhost routes
            - DEV_PORT comes from .env first, then ENV['DEV_PORT'], then 3000
        USAGE
      end

      def build_url(route)
        raise Error, 'ob only accepts local routes, not full URLs' if full_url?(route)

        path, query, fragment = route_components(route)
        uri_options = { host: 'localhost', port: resolved_dev_port.to_i, path: path, query: query, fragment: fragment }
        URI::HTTP.build(**uri_options).to_s
      rescue URI::Error => e
        raise Error, "Invalid route: #{e.message}"
      end

      def route_components(route)
        raw_route = route.to_s.strip
        route_without_fragment, fragment = raw_route.split('#', 2)
        path_part, query = route_without_fragment.to_s.split('?', 2)

        [normalized_path(path_part), presence(query), presence(fragment)]
      end

      def normalized_path(path_part)
        cleaned = path_part.to_s
        return '/' if cleaned.empty?

        cleaned.start_with?('/') ? cleaned : "/#{cleaned}"
      end

      def resolved_dev_port
        info = dev_port_resolution
        note_port_fallback(info[:message])

        port = info.fetch(:port)
        raise Error, "DEV_PORT must be numeric, got #{port.inspect}" unless port.match?(/\A\d+\z/)
        raise Error, "DEV_PORT must be between 1 and 65535, got #{port.inspect}" unless (1..65_535).cover?(port.to_i)

        port.to_i
      end

      def print_url_command
        return usage_error if @argv.length > 2

        @stdout.puts(build_url(@argv[1]))
        0
      end

      def dev_port_from_env_file
        return unless File.file?(env_path)

        lines = File.readlines(env_path, chomp: true)
        env_value(lines, 'DEV_PORT')
      rescue StandardError => e
        raise Error, "Could not read #{env_path}: #{e.message}"
      end

      def env_value(lines, key)
        line = lines.reverse.find { |entry| entry.start_with?("#{key}=") }
        value = line&.split('=', 2)&.last
        value unless value&.empty?
      end

      def dev_port_resolution
        env_file_port = dev_port_from_env_file
        return { port: env_file_port, message: nil } if env_file_port

        env_file_fallback_resolution
      end

      def env_file_fallback_resolution
        env_port = presence(@env['DEV_PORT'])
        return existing_env_file_resolution(env_port) if File.file?(env_path)

        missing_env_file_resolution(env_port)
      end

      def existing_env_file_resolution(env_port)
        return env_resolution_from_env_var(env_port) if env_port

        {
          port: '3000',
          message: [
            "#{env_path} does not define DEV_PORT",
            "and ENV['DEV_PORT'] is unset; falling back to localhost:3000."
          ].join(' ')
        }
      end

      def missing_env_file_resolution(env_port)
        return missing_env_file_resolution_from_env_var(env_port) if env_port

        {
          port: '3000',
          message: [
            "#{env_path} was not found",
            "and ENV['DEV_PORT'] is unset; falling back to localhost:3000."
          ].join(' ')
        }
      end

      def env_resolution_from_env_var(env_port)
        {
          port: env_port,
          message: "#{env_path} does not define DEV_PORT; falling back to ENV['DEV_PORT']=#{env_port}."
        }
      end

      def missing_env_file_resolution_from_env_var(env_port)
        {
          port: env_port,
          message: "#{env_path} was not found; falling back to ENV['DEV_PORT']=#{env_port}."
        }
      end

      def note_port_fallback(message)
        return unless message
        return if @port_fallback_noted

        @stderr.puts("Info: #{message}")
        @port_fallback_noted = true
      end

      def open_browser(url)
        command = opener_command
        raise Error, "Could not find a browser opener for #{@host_os.inspect}" unless command
        raise Error, "Failed to open browser with #{command}" unless run_opener(command, url)
      end

      def opener_command
        opener_candidates.find { |command| command_available?(command) }
      end

      def run_opener(command, url)
        system(command, url)
      end

      def command_available?(command)
        @env.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
          candidate = File.join(directory, command)
          File.file?(candidate) && File.executable?(candidate)
        end
      end

      def opener_candidates
        return ['open'] if @host_os.match?(/darwin/i)

        ['xdg-open']
      end

      def env_path = File.join(app_root, ENV_FILE_NAME)

      def app_root
        @app_root ||= begin
          explicit_root = presence(@env[APP_ROOT_ENV_KEY])
          explicit_root ? File.expand_path(explicit_root) : discover_app_root(File.expand_path(@cwd))
        end
      end

      def discover_app_root(start_dir)
        current = start_dir

        loop do
          return current if File.file?(File.join(current, 'Gemfile'))

          parent = File.dirname(current)
          break if parent == current

          current = parent
        end

        start_dir
      end

      def full_url?(route)
        route.to_s.match?(%r{\A[a-z][a-z0-9+\-.]*://}i)
      end

      def presence(value)
        value = value.to_s
        value.empty? ? nil : value
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
