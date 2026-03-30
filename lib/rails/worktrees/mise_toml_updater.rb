module Rails
  module Worktrees
    # Safely updates mise config to load the worktree-local .env.
    class MiseTomlUpdater
      Result = Struct.new(:content, :changed, :status, :messages) do
        def changed?
          changed
        end
      end

      ENV_SECTION_PATTERN = /\A\s*\[env\]\s*(?:#.*)?\z/
      ENV_FILE_PATTERN = /\A\s*_.file\s*=\s*["']\.env["']\s*(?:#.*)?\z/
      SECTION_PATTERN = /\A\s*\[[^\]]+\]\s*(?:#.*)?\z/
      ENV_FILE_ENTRY = '_.file = ".env"'.freeze

      def initialize(content:, file_name:)
        @content = content
        @file_name = file_name
      end

      def call
        lines = @content.lines(chomp: true)
        return update_existing_env_section(lines) if env_section_present?(lines)

        append_env_section(lines)
      end

      private

      def update_existing_env_section(lines)
        env_section_start, env_section_end = env_section_bounds(lines)
        return identical_result if env_file_configured?(lines, env_section_start, env_section_end)

        updated_lines = lines.dup
        updated_lines.insert(env_section_end, ENV_FILE_ENTRY)
        updated_result(rebuild_content(updated_lines, trailing_newline: @content.end_with?("\n")))
      end

      def append_env_section(lines)
        updated_lines = lines.dup
        updated_lines << '' if updated_lines.any? && !updated_lines.last.empty?
        updated_lines << '[env]'
        updated_lines << ENV_FILE_ENTRY

        updated_result(rebuild_content(updated_lines, trailing_newline: true))
      end

      def updated_result(content)
        Result.new(content, true, :updated, ["Configured #{@file_name} to load .env from [env]."])
      end

      def identical_result
        Result.new(@content, false, :identical, ["#{@file_name} already loads .env from [env]."])
      end

      def env_section_bounds(lines)
        start_index = lines.find_index { |line| line.match?(ENV_SECTION_PATTERN) }
        return [nil, nil] unless start_index

        end_index = ((start_index + 1)...lines.length).find do |index|
          lines[index].match?(SECTION_PATTERN)
        end || lines.length
        [start_index, end_index]
      end

      def env_section_present?(lines)
        env_section_bounds(lines).first
      end

      def env_file_configured?(lines, start_index, end_index)
        lines[(start_index + 1)...end_index].any? { |line| line.match?(ENV_FILE_PATTERN) }
      end

      def rebuild_content(lines, trailing_newline:)
        content = lines.join("\n")
        return content if content.empty? || !trailing_newline

        "#{content}\n"
      end
    end
  end
end
