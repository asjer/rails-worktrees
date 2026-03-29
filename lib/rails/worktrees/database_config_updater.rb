# frozen_string_literal: true

module Rails
  module Worktrees
    # Safely patches common database.yml layouts for worktree suffixes.
    class DatabaseConfigUpdater
      Result = Struct.new(:content, :changed, :messages) do
        def changed?
          changed
        end
      end

      SUFFIX_TEMPLATE = "<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>"
      SUPPORTED_ENVIRONMENTS = %w[development test].freeze
      DATABASE_LINE_PATTERN = /\A(\s*database:\s*)(.+?)(\s*(?:#.*)?\n?)\z/
      SECTION_PATTERN = /\A([A-Za-z0-9_]+):(?:\s|$)/

      def initialize(content:)
        @content = content
      end

      def call
        state = { found: Hash.new(0), patched: 0, unsupported: [], environment: nil }
        lines = @content.lines.map.with_index { |line, index| patch_line(line, index, state) }

        Result.new(
          lines.join,
          state[:patched].positive?,
          build_messages(state[:found], state[:patched], state[:unsupported])
        )
      end

      private

      def patch_line(line, index, state)
        state[:environment] = next_environment_for(line, state[:environment])
        return line unless state[:environment]

        match = line.match(DATABASE_LINE_PATTERN)
        return line unless match

        state[:found][state[:environment]] += 1
        apply_patch(match, index, state)
      end

      def apply_patch(match, index, state)
        patched_value = patch_database_value(match[2].strip, state[:environment])

        if patched_value
          state[:patched] += 1 unless patched_value == match[2].strip
          "#{match[1]}#{patched_value}#{match[3]}"
        else
          state[:unsupported] << { environment: state[:environment], line: index + 1, value: match[2].strip }
          match.string
        end
      end

      def next_environment_for(line, current_environment)
        section_name = top_level_section_name(line)
        return current_environment unless section_name
        return section_name if SUPPORTED_ENVIRONMENTS.include?(section_name)

        nil
      end

      def top_level_section_name(line)
        return unless line.lstrip == line

        match = line.match(SECTION_PATTERN)
        match && match[1]
      end

      def patch_database_value(value, environment)
        return value if value.include?('WORKTREE_DATABASE_SUFFIX')
        return if value.include?('<%')

        quote = value[/\A['"]/]
        raw_value = quote ? value.delete_prefix(quote).delete_suffix(quote) : value
        patched = patch_segmented_database_name(raw_value, environment) ||
                  patch_database_file_path(raw_value, environment)
        return unless patched

        quote ? "#{quote}#{patched}#{quote}" : patched
      end

      def patch_segmented_database_name(raw_value, environment)
        return unless raw_value.match?(/\A[\w-]+\z/)

        segments = raw_value.split('_')
        environment_index = segments.index(environment)
        return unless environment_index

        segments[environment_index] = "#{segments[environment_index]}#{SUFFIX_TEMPLATE}"
        segments.join('_')
      end

      def patch_database_file_path(raw_value, environment)
        match = raw_value.match(
          /\A(?<prefix>.*?)(?<environment>development|test)(?<tail>(?:[_-][\w-]+)*)(?<extension>\.[A-Za-z0-9.]+)\z/
        )
        return unless match
        return unless match[:environment] == environment

        [match[:prefix], match[:environment], SUFFIX_TEMPLATE, match[:tail], match[:extension]].join
      end

      def build_messages(found_entries, patched_entries, unsupported_entries)
        messages = [status_message(found_entries, patched_entries, unsupported_entries)].compact
        return messages if unsupported_entries.empty?

        line_numbers = unsupported_entries.map { |entry| entry[:line] }.join(', ')
        messages << "Could not safely rewrite config/database.yml on line(s) #{line_numbers}. " \
                    "Add #{SUFFIX_TEMPLATE} to the development/test database name(s) manually."
      end

      def status_message(found_entries, patched_entries, unsupported_entries)
        total = found_entries.values.sum
        if patched_entries.positive?
          noun = patched_entries == 1 ? 'entry' : 'entries'
          "Updated #{patched_entries} development/test database #{noun} to include WORKTREE_DATABASE_SUFFIX."
        elsif total.positive? && unsupported_entries.empty?
          'Development/test database names already include WORKTREE_DATABASE_SUFFIX.'
        elsif total.zero?
          'No development/test database entries matched a supported auto-update layout.'
        end
      end
    end
  end
end
