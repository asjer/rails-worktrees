require 'json'
require 'open3'

module Rails
  module Worktrees
    # Resolves runtime environment variables from mise for setup subprocesses.
    class MiseEnvironment
      Result = Struct.new(:env, :messages)

      CONFIG_FILES = %w[mise.toml .mise.toml].freeze

      def initialize(target_dir:, env:)
        @target_dir = target_dir
        @env = env
      end

      def call
        return Result.new(env: {}, messages: []) unless mise_available?

        messages = []
        trust_config!(messages)
        env = resolved_env
        messages << '🧰 Activating mise toolchain...' if project_config_file || !env.empty?

        Result.new(env: env, messages: messages.uniq)
      end

      private

      def mise_available?
        _stdout_str, _stderr_str, status = Open3.capture3(@env, 'mise', '--version', chdir: @target_dir)
        status.success?
      rescue Errno::ENOENT
        false
      end

      def trust_config!(messages)
        config_file = project_config_file
        return unless config_file

        messages << '🔐 Trusting mise config...'

        ensure_trusted!(config_file)
      end

      def ensure_trusted!(config_file)
        _stdout_str, stderr_str, status = Open3.capture3(
          @env,
          'mise',
          'trust',
          config_file,
          chdir: @target_dir
        )

        return if status.success?

        raise Error, "mise trust failed: #{command_error(stderr_str)}"
      end

      def resolved_env
        @resolved_env ||= begin
          stdout_str, stderr_str, status = Open3.capture3(@env, 'mise', 'env', '--json', chdir: @target_dir)
          raise Error, "mise env --json failed: #{command_error(stderr_str)}" unless status.success?

          JSON.parse(stdout_str).each_with_object({}) do |(key, value), env|
            next if value.nil?

            env[key] = value.to_s
          end
        rescue JSON::ParserError => e
          raise Error, "mise env --json returned invalid JSON: #{e.message}"
        end
      end

      def project_config_file
        @project_config_file ||= CONFIG_FILES
                                 .map { |file_name| File.join(@target_dir, file_name) }
                                 .find { |path| File.file?(path) }
      end

      def command_error(stderr_str)
        message = stderr_str.to_s.strip
        message.empty? ? 'unknown error' : message
      end
    end
  end
end
