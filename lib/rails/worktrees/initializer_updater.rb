require 'erb'

module Rails
  module Worktrees
    # Safely updates the generated initializer to use the current managed app-config format.
    # rubocop:disable Metrics/ClassLength
    class InitializerUpdater
      Result = Struct.new(:content, :changed, :status, :messages) do
        def changed?
          changed
        end
      end

      TEMPLATE_PATH = File.expand_path('../../generators/rails/worktrees/templates/rails_worktrees.rb.tt', __dir__)
      FILE_ENCODING = 'UTF-8'.freeze
      CURRENT_WRAPPER_CALL = 'Rails.application.config.x.rails_worktrees.tap do |config|'.freeze
      CONFIGURE_CALL = 'Rails::Worktrees.configure do |config|'.freeze
      KNOWN_GUARD_FRAGMENTS = [
        "Gem.loaded_specs.key?('rails-worktrees')",
        'defined?(Rails::Worktrees)',
        'Rails::Worktrees.respond_to?(:configure)'
      ].freeze

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
          ['config/initializers/rails_worktrees.rb already uses the current managed initializer format.']
        )
      end

      def updated_result(content)
        Result.new(
          content,
          content != @content,
          :updated,
          ['Updated config/initializers/rails_worktrees.rb to use the current managed initializer format.']
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

      def current_wrapper_present?
        !extract_current_wrapper_body(@content.to_s.strip.lines).nil?
      end

      def normalized_body = extract_existing_body&.then { |body| normalize_body(body) }

      def extract_existing_body
        stripped = @content.to_s.strip
        return if stripped.empty?

        body = extract_current_wrapper_body(stripped.lines)
        return body if body

        body = extract_guarded_configure_body(stripped.lines)
        return body if body

        body = extract_plain_configure_body(stripped.lines)
        return body if body

        nil
      end

      def extract_current_wrapper_body(lines)
        return unless lines.first&.strip == CURRENT_WRAPPER_CALL && lines.last&.strip == 'end'

        lines[1...-1].join.rstrip
      end

      def extract_guarded_configure_body(lines)
        return unless guarded_configure_block?(lines)

        configure_index = lines.index { |line| line.strip == CONFIGURE_CALL }
        return unless guarded_configure_lines(lines, configure_index).all? { |line| known_guard_line?(line) }

        lines[(configure_index + 1)...-2].join.rstrip
      end

      def extract_plain_configure_body(lines)
        return unless lines.first&.strip == CONFIGURE_CALL && lines.last&.strip == 'end'

        lines[1...-1].join.rstrip
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

        minimum_indent = body_indent(body_lines)

        body_lines.map do |line|
          next line if line.strip.empty?

          normalize_body_line(line, minimum_indent)
        end.join.rstrip
      end

      def rebuild_content(body)
        content = [CURRENT_WRAPPER_CALL, body, 'end'].join("\n")
        @content.end_with?("\n") || @content.empty? ? "#{content}\n" : content
      end

      def render_default_template
        ERB.new(File.read(TEMPLATE_PATH, encoding: FILE_ENCODING), trim_mode: '-').result(
          template_context.instance_eval { binding }
        )
      end

      def template_context
        Struct.new(:options, :conductor_workspace_root).new({ 'conductor' => false },
                                                            "File.expand_path('~/Sites/conductor/workspaces')")
      end

      def guarded_configure_block?(lines)
        lines.last(2).map(&:strip) == %w[end end] && lines.any? { |line| line.strip == CONFIGURE_CALL }
      end

      def guarded_configure_lines(lines, configure_index)
        lines[0...configure_index].reject { |line| line.strip.empty? }.map(&:rstrip)
      end

      def body_indent(body_lines)
        body_lines.reject { |line| line.strip.empty? }
                  .map { |line| line[/\A\s*/].length }
                  .min || 0
      end

      def normalize_body_line(line, minimum_indent)
        trimmed = line.sub(/\A\s{0,#{minimum_indent}}/, '')
        "  #{trimmed}"
      end

      def current_guard_present? = current_wrapper_present?

      def wrapped_body = normalized_body
    end
    # rubocop:enable Metrics/ClassLength
  end
end
