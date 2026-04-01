require 'erb'

module Rails
  module Worktrees
    # Safely updates the generated initializer to use the current gem-loading guard.
    # rubocop:disable Metrics/ClassLength
    class InitializerUpdater
      Result = Struct.new(:content, :changed, :status, :messages) do
        def changed?
          changed
        end
      end

      TEMPLATE_PATH = File.expand_path('../../generators/rails/worktrees/templates/rails_worktrees.rb.tt', __dir__)
      CURRENT_GUARD_LINES = [
        "if Gem.loaded_specs.key?('rails-worktrees') &&",
        '    defined?(Rails::Worktrees) &&',
        '    Rails::Worktrees.respond_to?(:configure)'
      ].freeze
      KNOWN_GUARD_FRAGMENTS = [
        "Gem.loaded_specs.key?('rails-worktrees')",
        'defined?(Rails::Worktrees)',
        'Rails::Worktrees.respond_to?(:configure)'
      ].freeze
      CONFIGURE_CALL = 'Rails::Worktrees.configure do |config|'.freeze
      LEGACY_GUARD = /\Aif defined\?\(Rails::Worktrees\)\n(?<body>.*)\nend\z/m

      def self.default_content = new(content: '').send(:render_default_template)

      def initialize(content:) = @content = content

      def call
        return identical_result if current_guard_present?
        return updated_result(self.class.default_content) if blank_content?

        body = wrapped_body
        return skip_result unless body

        updated_result(rebuild_content(body))
      end

      private

      def identical_result
        Result.new(
          @content,
          false,
          :identical,
          ['config/initializers/rails_worktrees.rb already uses the current safety guard.']
        )
      end

      def updated_result(content)
        Result.new(
          content,
          content != @content,
          :updated,
          ['Updated config/initializers/rails_worktrees.rb to use the current safety guard.']
        )
      end

      def skip_result
        Result.new(
          @content,
          false,
          :skip,
          ['config/initializers/rails_worktrees.rb is too custom to update automatically; review it manually.']
        )
      end

      def blank_content? = @content.to_s.strip.empty?

      def current_guard_present?
        !extract_known_guard_body(@content.to_s.strip.lines, required_guard_lines: CURRENT_GUARD_LINES).nil?
      end

      def wrapped_body = extract_existing_body&.then { |body| normalize_body(body) }

      def extract_existing_body
        stripped = @content.to_s.strip
        return if stripped.empty?

        return Regexp.last_match[:body] if stripped.match(LEGACY_GUARD)

        body = extract_known_guard_body(stripped.lines)
        return body if body

        body = extract_plain_configure_body(stripped.lines)
        return body if body

        nil
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def extract_known_guard_body(lines, required_guard_lines: nil)
        return if lines.empty? || lines.last.strip != 'end'

        configure_index = lines.index { |line| line.strip == CONFIGURE_CALL }
        return unless configure_index

        guard_lines = lines[0...configure_index].reject { |line| line.strip.empty? }.map(&:rstrip)
        return unless guard_lines.all? { |line| known_guard_line?(line) }
        return if required_guard_lines && guard_lines != required_guard_lines

        lines[configure_index...-1].join.rstrip
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def extract_plain_configure_body(lines)
        return unless lines.first&.strip == CONFIGURE_CALL && lines.last&.strip == 'end'

        lines.join.rstrip
      end

      def known_guard_line?(line)
        stripped = line.strip
        return true if stripped.empty?

        normalized = stripped.delete_suffix('&&').strip.sub(/\Aif\s+/, '')
        KNOWN_GUARD_FRAGMENTS.include?(normalized)
      end

      def normalize_body(body)
        body_lines = body.rstrip.lines
        return '' if body_lines.empty?

        return body.rstrip if body_lines.first.start_with?('  ')

        body_lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join.rstrip
      end

      def rebuild_content(body)
        content = [CURRENT_GUARD_LINES.join("\n"), body, 'end'].join("\n")
        @content.end_with?("\n") || @content.empty? ? "#{content}\n" : content
      end

      def render_default_template
        ERB.new(File.read(TEMPLATE_PATH), trim_mode: '-').result(template_context.instance_eval { binding })
      end

      def template_context
        Struct.new(:options, :conductor_workspace_root).new({ 'conductor' => false },
                                                            "File.expand_path('~/Sites/conductor/workspaces')")
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
