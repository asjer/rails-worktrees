require 'pathname'
require 'zlib'

module Rails
  module Worktrees
    # Creates or updates a worktree-local .env with deterministic defaults.
    # rubocop:disable Metrics/ClassLength
    class EnvBootstrapper
      Result = Struct.new(:changed, :env_path, :messages) do
        def changed? = changed

        attr_accessor :values
      end

      ENV_FILE_NAME = '.env'.freeze
      FILE_ENCODING = 'UTF-8'.freeze

      def initialize(target_dir:, worktree_name:, configuration:, peer_roots: nil)
        @target_dir = target_dir
        @worktree_name = worktree_name
        @configuration = configuration
        @peer_roots = peer_roots.nil? ? nil : Array(peer_roots).compact
      end

      def call(dry_run: false)
        return disabled_result unless @configuration.bootstrap_env

        lines = existing_env_lines
        write_missing_updates(lines, resolved_values(lines), dry_run: dry_run)
      end

      def preview = result(false, [], resolved_values(existing_env_lines))

      private

      def disabled_result = result(false, [], {})

      def unchanged_result(values, dry_run: false)
        message = if dry_run
                    "Would not change #{display_path(env_path)}; it already defines " \
                      'DEV_PORT and WORKTREE_DATABASE_SUFFIX'
                  else
                    "#{display_path(env_path)} already defines DEV_PORT and WORKTREE_DATABASE_SUFFIX"
                  end
        result(false, [message], values)
      end

      def existing_env_lines
        File.exist?(env_path) ? File.readlines(env_path, chomp: true, encoding: FILE_ENCODING) : []
      end

      def resolved_values(lines)
        dev_port = (env_value(lines, 'DEV_PORT') || allocate_dev_port).to_s

        {
          'DEV_PORT' => dev_port,
          'WORKTREE_DATABASE_SUFFIX' => env_value(lines, 'WORKTREE_DATABASE_SUFFIX') ||
            allocate_worktree_database_suffix(dev_port: dev_port)
        }
      end

      def write_missing_updates(existing_lines, values, dry_run: false)
        updates = missing_updates(existing_lines, values)
        return unchanged_result(values, dry_run: dry_run) if updates.empty?
        return dry_run_bootstrap_result(values, updates) if dry_run

        File.write(env_path, with_missing_entries(existing_lines, updates))
        result(true, ["Bootstrapped #{display_path(env_path)} (#{formatted_updates(updates)})"], values)
      end

      def missing_updates(lines, values)
        values.each_with_object({}) do |(key, value), updates|
          updates[key] = value unless env_value(lines, key)
        end
      end

      def result(changed, messages, values)
        Result.new(changed, env_path, messages).tap do |bootstrap_result|
          bootstrap_result.values = values
        end
      end

      def env_path = @env_path ||= File.join(@target_dir, ENV_FILE_NAME)

      def with_missing_entries(lines, updates)
        output = lines.dup
        output << '' if output.any? && !output.last.empty?
        updates.each { |key, value| output << "#{key}=#{value}" }
        "#{output.join("\n")}\n"
      end

      def env_value(lines, key)
        line = lines.reverse.find { |entry| entry.start_with?("#{key}=") }
        value = line&.split('=', 2)&.last
        value unless value&.empty?
      end

      def allocate_dev_port
        ports = configured_port_range.to_a
        raise ArgumentError, 'dev_port_range must contain at least one port' if ports.empty?

        claimed_ports = claimed_peer_ports
        candidate_ports(ports).find { |port| !claimed_ports.include?(port) } ||
          raise(ArgumentError, "No available DEV_PORT values remain in #{configured_port_range}")
      end

      def dry_run_bootstrap_result(values, updates)
        result(false, ["Would bootstrap #{display_path(env_path)} (#{formatted_updates(updates)})"], values)
      end

      def candidate_ports(ports)
        start_index = Zlib.crc32(@worktree_name) % ports.length
        ports.rotate(start_index)
      end

      def claimed_peer_ports
        peer_paths.filter_map do |path|
          next if File.expand_path(path) == File.expand_path(@target_dir)

          port = env_value(peer_env_lines(path), 'DEV_PORT')
          next unless port&.match?(/\A\d+\z/)

          port.to_i
        end.to_set
      end

      def peer_env_lines(path)
        env_file = File.join(path, ENV_FILE_NAME)
        File.exist?(env_file) ? File.readlines(env_file, chomp: true, encoding: FILE_ENCODING) : []
      end

      def peers_root = File.dirname(@target_dir)

      def peer_paths
        return @peer_roots unless @peer_roots.nil?

        Dir.glob(File.join(peers_root, '*')).select { |path| File.directory?(path) }
      end

      def configured_port_range = @configuration.dev_port_range

      def allocate_worktree_database_suffix(dev_port:)
        base_candidate = format_worktree_database_suffix(@worktree_name)
        return base_candidate unless claimed_peer_suffixes.include?(base_candidate)

        suffix_with_token(@worktree_name, dev_port.to_s)
      end

      def format_worktree_database_suffix(value)
        suffix = value.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').squeeze('_')
        suffix = suffix[0, @configuration.worktree_database_suffix_max_length]
        suffix = suffix.to_s.sub(/_+\z/, '')
        suffix = 'worktree' if suffix.empty?
        "_#{suffix}"
      end

      def suffix_with_token(value, token)
        slug = normalized_suffix_slug(value)
        normalized_token = token.to_s.downcase.gsub(/[^a-z0-9]+/, '')
        max_length = @configuration.worktree_database_suffix_max_length
        available_slug_length = max_length - normalized_token.length - 1

        composed_slug = if available_slug_length.positive?
                          [slug[0, available_slug_length], normalized_token].reject(&:empty?).join('_')
                        else
                          normalized_token[0, max_length]
                        end

        format_worktree_database_suffix(composed_slug)
      end

      def normalized_suffix_slug(value)
        slug = value.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').squeeze('_')
        slug.empty? ? 'worktree' : slug
      end

      def claimed_peer_suffixes
        peer_paths.each_with_object(Set.new) do |path, suffixes|
          next if File.expand_path(path) == File.expand_path(@target_dir)

          suffix = env_value(peer_env_lines(path), 'WORKTREE_DATABASE_SUFFIX')
          suffixes << suffix if suffix
        end
      end

      def formatted_updates(updates) = updates.map { |key, value| "#{key}=#{value}" }.join(', ')

      def display_path(path)
        target_path = Pathname.new(path)
        root_path = Pathname.new(@target_dir)
        target_path.relative_path_from(root_path).to_s
      rescue ArgumentError
        path
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
