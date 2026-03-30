module Rails
  module Worktrees
    # Safely updates config/puma.rb to bind Puma to the worktree-local DEV_PORT.
    class PumaConfigUpdater
      Result = Struct.new(:content, :changed, :status, :messages) do
        def changed?
          changed
        end
      end

      STANDARD_PORT_LINE = "port ENV['DEV_PORT'] || ENV.fetch('PORT', 3000)".freeze
      CURRENT_PORT_PATTERN = /\A\s*port\s+ENV\.fetch\(["']PORT["'],\s*3000\)\s*(?:#.*)?\z/
      LEGACY_PORT_PATTERN = /\A\s*port\s+ENV\.fetch\(["']PORT["']\)\s*\{\s*3000\s*\}\s*(?:#.*)?\z/
      PORT_LINE_PATTERN = /\A\s*port\s+/
      DEV_PORT_ACCESS_PATTERN = /ENV\[(["'])DEV_PORT\1\]/
      DEV_PORT_FETCH_PATTERN = /ENV\.fetch\((["'])DEV_PORT\1(?:\s*,|\s*\))/

      def initialize(content:)
        @content = content
      end

      def call
        lines = @content.lines(chomp: true)
        return identical_result(@content) if dev_port_configured?(lines)

        port_line_indexes = supported_port_line_indexes(lines)
        return skip_result if port_line_indexes.empty?

        updated_content = rebuild_content(
          replace_port_lines(lines, port_line_indexes),
          trailing_newline: @content.end_with?("\n")
        )

        updated_result(updated_content)
      end

      private

      def updated_result(content)
        Result.new(content, true, :updated, ['Updated config/puma.rb to prefer DEV_PORT before PORT.'])
      end

      def identical_result(content)
        Result.new(content, false, :identical, ['config/puma.rb already uses DEV_PORT-aware port binding.'])
      end

      def skip_result
        Result.new(
          @content,
          false,
          :skip,
          ['No supported Puma port binding found in config/puma.rb; update it manually if needed.']
        )
      end

      def dev_port_configured?(lines)
        lines.any? do |line|
          line.match?(PORT_LINE_PATTERN) &&
            (line.match?(DEV_PORT_ACCESS_PATTERN) || line.match?(DEV_PORT_FETCH_PATTERN))
        end
      end

      def supported_port_line_indexes(lines)
        lines.each_index.select { |index| supported_port_line?(lines[index]) }
      end

      def supported_port_line?(line)
        line.match?(CURRENT_PORT_PATTERN) || line.match?(LEGACY_PORT_PATTERN)
      end

      def replace_port_lines(lines, port_line_indexes)
        lines.dup.tap do |updated_lines|
          port_line_indexes.each do |index|
            original_line = lines[index]
            indent = original_line[/\A\s*/]
            trailing_comment = original_line[/(\s*#.*)\z/, 1].to_s

            updated_lines[index] = "#{indent}#{STANDARD_PORT_LINE}#{trailing_comment}"
          end
        end
      end

      def rebuild_content(lines, trailing_newline:)
        content = lines.join("\n")
        return content if content.empty? || !trailing_newline

        "#{content}\n"
      end
    end
  end
end
