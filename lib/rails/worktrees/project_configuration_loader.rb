require 'pathname'

module Rails
  module Worktrees
    # Loads project-level configuration from the generated initializer without booting the full app.
    class ProjectConfigurationLoader
      CURRENT_WRAPPER_CALL = 'Rails.application.config.x.rails_worktrees.tap do |config|'.freeze
      CONFIGURE_CALL = 'Rails::Worktrees.configure do |config|'.freeze
      INITIALIZER_RELATIVE_PATH = 'config/initializers/rails_worktrees.rb'.freeze
      KNOWN_GUARD_FRAGMENTS = [
        "Gem.loaded_specs.key?('rails-worktrees')",
        'defined?(Rails::Worktrees)',
        'Rails::Worktrees.respond_to?(:configure)'
      ].freeze
      TEMP_RAILS_ROOT_MUTEX = Mutex.new

      def initialize(root:, configuration: Rails::Worktrees.configuration)
        @root = root
        @configuration = configuration
      end

      def call
        return configuration unless initializer_path && File.file?(initializer_path)

        body = extract_configuration_body(File.read(initializer_path))
        return configuration unless body

        recorder = AssignmentRecorder.new(configuration)

        with_temporary_rails_root do
          evaluate_configuration_body(body, recorder)
        end

        Rails::Worktrees.apply_application_configuration(recorder.values, configuration: configuration)
      end

      private

      attr_reader :configuration, :root

      def initializer_path
        return @initializer_path if defined?(@initializer_path)

        @initializer_path = project_root&.join(INITIALIZER_RELATIVE_PATH)&.to_s
      end

      def project_root
        return @project_root if defined?(@project_root)

        @project_root = discover_project_root
      end

      def discover_project_root
        current = Pathname(root).expand_path

        current.ascend do |path|
          return path if File.file?(path.join(INITIALIZER_RELATIVE_PATH))
        end

        nil
      end

      def evaluate_configuration_body(body, recorder)
        # Evaluates a managed initializer body like:
        #
        #   proc do |config|
        #     config.branch_prefix = '🌿'
        #   end
        # rubocop:disable Security/Eval, Style/DocumentDynamicEvalDefinition, Style/EvalWithLocation
        Kernel.eval(
          "proc do |config|\n#{body.rstrip}\nend",
          TOPLEVEL_BINDING,
          initializer_path,
          1
        ).call(recorder)
        # rubocop:enable Security/Eval, Style/DocumentDynamicEvalDefinition, Style/EvalWithLocation
      end

      def extract_configuration_body(content)
        stripped = content.to_s.strip
        return if stripped.empty?

        lines = stripped.lines

        extract_single_block_body(lines, CURRENT_WRAPPER_CALL) ||
          extract_guarded_configure_body(lines) ||
          extract_single_block_body(lines, CONFIGURE_CALL)
      end

      def extract_single_block_body(lines, opening_line)
        return unless lines.first&.strip == opening_line && lines.last&.strip == 'end'

        lines[1...-1].join
      end

      def extract_guarded_configure_body(lines)
        return unless guarded_configure_block?(lines)

        configure_index = lines.index { |line| line.strip == CONFIGURE_CALL }
        return unless guarded_configure_lines(lines, configure_index).all? { |line| known_guard_line?(line) }

        lines[(configure_index + 1)...-2].join
      end

      def known_guard_line?(line)
        normalized = line.strip.delete_suffix('&&').strip.sub(/\Aif\s+/, '')
        KNOWN_GUARD_FRAGMENTS.include?(normalized)
      end

      def guarded_configure_block?(lines)
        lines.last(2).map(&:strip) == %w[end end] && lines.any? { |line| line.strip == CONFIGURE_CALL }
      end

      def guarded_configure_lines(lines, configure_index)
        lines[0...configure_index].reject { |line| line.strip.empty? }.map(&:rstrip)
      end

      def with_temporary_rails_root
        self.class::TEMP_RAILS_ROOT_MUTEX.synchronize do
          override_state = build_rails_root_override_state

          apply_temporary_rails_root(override_state, project_root)
          yield
        ensure
          restore_rails_root(override_state)
        end
      end

      def build_rails_root_override_state
        had_root = Rails.respond_to?(:root)
        { singleton_class: Rails.singleton_class, had_root: had_root,
          previous_root: (Rails.method(:root) if had_root), overridden: false }
      end

      def apply_temporary_rails_root(override_state, resolved_project_root)
        override_state[:singleton_class].send(:define_method, :root) { resolved_project_root }
        override_state[:overridden] = true
      end

      def restore_rails_root(override_state)
        return unless override_state

        override_state[:singleton_class].send(:remove_method, :root) if override_state[:overridden]
        return unless override_state[:had_root]

        override_state[:singleton_class].send(:define_method, :root, override_state[:previous_root])
      end

      # Records config.<name> = value assignments without raising on unknown keys.
      class AssignmentRecorder
        attr_reader :values

        def initialize(configuration = nil)
          @configuration = configuration
          @values = {}
        end

        def method_missing(method_name, *args)
          name = method_name.to_s

          if setter_call?(name, args)
            values[name.delete_suffix('=').to_sym] = args.first
          elsif getter_call?(name, args)
            values.fetch(name.to_sym) { configuration_value_for(method_name) }
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          name = method_name.to_s

          setter_name?(name) || getter_name?(name) || super
        end

        private

        attr_reader :configuration

        def setter_call?(name, args)
          setter_name?(name) && args.length == 1
        end

        def getter_call?(name, args)
          getter_name?(name) && args.empty?
        end

        def setter_name?(name)
          name.end_with?('=')
        end

        def getter_name?(name)
          !setter_name?(name)
        end

        def configuration_value_for(method_name)
          fallback_configuration = configuration
          return unless fallback_configuration.respond_to?(method_name)

          fallback_configuration.public_send(method_name)
        end
      end
    end
  end
end
