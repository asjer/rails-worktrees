module Rails
  module Worktrees
    # Safely updates Procfile.dev to use the worktree-local DEV_PORT.
    class ProcfileUpdater
      Result = Struct.new(:content, :changed, :status, :messages) do
        def changed?
          changed
        end
      end

      STANDARD_WEB_ENTRY = 'web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}'.freeze
      WEB_ENTRY_PATTERN = /\Aweb:\s*.*\z/

      def initialize(content:)
        @content = content
      end

      def call
        lines = @content.lines(chomp: true)
        web_entry_indexes = web_entry_indexes(lines)
        return skip_result if web_entry_indexes.empty?

        updated_content = rebuild_content(
          replace_web_entries(lines, web_entry_indexes),
          trailing_newline: @content.end_with?("\n")
        )

        build_result(updated_content)
      end

      private

      def updated_result(content)
        Result.new(content, true, :updated, ['Updated Procfile.dev web entry to use DEV_PORT.'])
      end

      def identical_result(content)
        Result.new(content, false, :identical, ['Procfile.dev already uses the DEV_PORT-aware web entry.'])
      end

      def skip_result
        Result.new(@content, false, :skip, ['No web: entry found in Procfile.dev; update it manually if needed.'])
      end

      def web_entry_indexes(lines)
        lines.each_index.select { |index| lines[index].match?(WEB_ENTRY_PATTERN) }
      end

      def replace_web_entries(lines, web_entry_indexes)
        lines.dup.tap do |updated_lines|
          web_entry_indexes.each { |index| updated_lines[index] = STANDARD_WEB_ENTRY }
        end
      end

      def build_result(content)
        return identical_result(content) if content == @content

        updated_result(content)
      end

      def rebuild_content(lines, trailing_newline:)
        content = lines.join("\n")
        return content if content.empty? || !trailing_newline

        "#{content}\n"
      end
    end
  end
end
