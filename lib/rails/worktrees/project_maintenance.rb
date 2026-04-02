module Rails
  module Worktrees
    # Audits and prepares safe file-based maintenance updates for the current checkout.
    # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
    class ProjectMaintenance
      # rubocop:disable Style/RedundantStructKeywordInit
      Check = Struct.new(
        :identifier,
        :category,
        :headline,
        :messages,
        :relative_path,
        :status,
        :updated_content,
        :make_executable,
        :apply_messages,
        keyword_init: true
      ) do
        def ok?
          status == :ok
        end

        def fixable?
          status == :fixable
        end

        def warning?
          status == :warning
        end

        def updatable?
          !updated_content.nil?
        end
      end

      Report = Struct.new(:checks, keyword_init: true) do
        def fixable_checks
          checks.select(&:fixable?)
        end

        def warning_checks
          checks.select(&:warning?)
        end

        def ok?
          fixable_checks.empty? && warning_checks.empty?
        end
      end
      # rubocop:enable Style/RedundantStructKeywordInit

      TEMPLATE_ROOT = File.expand_path('../../generators/rails/worktrees/templates', __dir__)

      def initialize(root:)
        @root = root
      end

      def call
        Report.new(checks: maintenance_checks.compact)
      end

      private

      attr_reader :root

      def maintenance_checks
        [
          template_file_check(wrapper_config),
          initializer_check,
          database_check,
          optional_updater_check(procfile_config) { |content| ProcfileUpdater.new(content: content).call },
          optional_updater_check(puma_config) { |content| PumaConfigUpdater.new(content: content).call },
          mise_check,
          template_file_check(browser_wrapper_config)
        ]
      end

      def wrapper_config
        {
          identifier: :bin_wt,
          category: :install,
          relative_path: 'bin/wt',
          template_path: File.join(TEMPLATE_ROOT, 'bin/wt'),
          make_executable: true,
          optional: false
        }
      end

      def browser_wrapper_config
        {
          identifier: :bin_ob,
          category: :install,
          relative_path: 'bin/ob',
          template_path: File.join(TEMPLATE_ROOT, 'bin/ob'),
          make_executable: true,
          optional: true
        }
      end

      def template_file_check(config)
        path = absolute_path(config.fetch(:relative_path))
        return nil if config.fetch(:optional) && !File.exist?(path)

        desired_content = File.read(config.fetch(:template_path))
        return template_missing_check(config, desired_content) unless File.exist?(path)

        current_content = File.read(path)
        if current_content == desired_content
          if executable_mode_current?(config, path)
            return ok_check(config, "#{config.fetch(:relative_path)} is up to date.")
          end

          return executable_permission_check(config, desired_content)
        end

        fixable_check(
          config,
          "#{config.fetch(:relative_path)} differs from the managed template.",
          updated_content: desired_content,
          apply_messages: ["Updated #{config.fetch(:relative_path)} to match the managed template."],
          make_executable: config.fetch(:make_executable, false)
        )
      end

      def executable_mode_current?(config, path)
        !config.fetch(:make_executable, false) || File.executable?(path)
      end

      def executable_permission_check(config, desired_content)
        relative_path = config.fetch(:relative_path)
        fixable_check(
          config,
          "#{relative_path} needs its executable bit restored.",
          updated_content: desired_content,
          apply_messages: ["Restored executable permissions on #{relative_path}."],
          make_executable: true
        )
      end

      def template_missing_check(config, desired_content)
        fixable_check(
          config,
          "#{config.fetch(:relative_path)} is missing.",
          updated_content: desired_content,
          apply_messages: ["Created #{config.fetch(:relative_path)} from the managed template."],
          make_executable: config.fetch(:make_executable, false)
        )
      end

      def initializer_check
        config = {
          identifier: :initializer,
          category: :install,
          relative_path: 'config/initializers/rails_worktrees.rb',
          identical_headline: 'config/initializers/rails_worktrees.rb already uses the current managed initializer ' \
                              'format.',
          fixable_headline: 'config/initializers/rails_worktrees.rb can be updated automatically.',
          warning_headline: 'config/initializers/rails_worktrees.rb needs manual review.'
        }
        path = absolute_path(config.fetch(:relative_path))

        unless File.exist?(path)
          return fixable_check(
            config,
            "#{config.fetch(:relative_path)} is missing.",
            updated_content: InitializerUpdater.default_content,
            apply_messages: ['Created config/initializers/rails_worktrees.rb in the current managed initializer ' \
                             'format.']
          )
        end

        updater_result_check(config, InitializerUpdater.new(content: File.read(path)).call)
      end

      def database_check
        config = {
          identifier: :database,
          category: :config,
          relative_path: 'config/database.yml'
        }
        path = absolute_path(config.fetch(:relative_path))

        unless File.exist?(path)
          return warning_check(
            config,
            'config/database.yml is missing.',
            ['Add WORKTREE_DATABASE_SUFFIX support manually if this app uses a custom database setup.']
          )
        end

        result = DatabaseConfigUpdater.new(content: File.read(path)).call
        return updated_database_check(config, result) if result.changed?

        if database_configured?(result)
          return ok_check(
            config,
            'config/database.yml already includes WORKTREE_DATABASE_SUFFIX in supported entries.'
          )
        end

        warning_check(
          config,
          result.messages.first || 'config/database.yml needs manual review.',
          result.messages.drop(1)
        )
      end

      def updated_database_check(config, result)
        fixable_check(
          config,
          'config/database.yml can be updated automatically.',
          messages: result.messages.drop(1),
          updated_content: result.content,
          apply_messages: result.messages
        )
      end

      def database_configured?(result)
        result.messages.first == 'Development/test database names already include WORKTREE_DATABASE_SUFFIX.'
      end

      def procfile_config
        {
          identifier: :procfile,
          category: :config,
          relative_path: 'Procfile.dev',
          identical_headline: 'Procfile.dev already uses the DEV_PORT-aware web entry.',
          fixable_headline: 'Procfile.dev can be updated automatically.',
          warning_headline: 'Procfile.dev needs manual review.'
        }
      end

      def puma_config
        {
          identifier: :puma,
          category: :config,
          relative_path: 'config/puma.rb',
          identical_headline: 'config/puma.rb already prefers DEV_PORT.',
          fixable_headline: 'config/puma.rb can be updated automatically.',
          warning_headline: 'config/puma.rb needs manual review.'
        }
      end

      def optional_updater_check(config)
        path = absolute_path(config.fetch(:relative_path))
        return unless File.exist?(path)

        updater_result_check(config, yield(File.read(path)))
      end

      def mise_check
        relative_path = %w[mise.toml .mise.toml].find { |candidate| File.exist?(absolute_path(candidate)) }
        return unless relative_path

        config = {
          identifier: :mise,
          category: :config,
          relative_path: relative_path,
          identical_headline: "#{relative_path} already loads .env from [env].",
          fixable_headline: "#{relative_path} can be updated automatically.",
          warning_headline: "#{relative_path} needs manual review."
        }

        updater_result_check(config, mise_updater_result(relative_path))
      end

      def mise_updater_result(relative_path)
        MiseTomlUpdater.new(
          content: File.read(absolute_path(relative_path)),
          file_name: File.basename(relative_path)
        ).call
      end

      def updater_result_check(config, result)
        case result.status
        when :identical
          ok_check(config, config.fetch(:identical_headline))
        when :updated
          fixable_check(
            config,
            config.fetch(:fixable_headline),
            updated_content: result.content,
            apply_messages: result.messages
          )
        else
          warning_check(config, config.fetch(:warning_headline), result.messages)
        end
      end

      def ok_check(config, headline)
        build_check(config, status: :ok, headline: headline)
      end

      def warning_check(config, headline, messages = [])
        build_check(config, status: :warning, headline: headline, messages: messages)
      end

      def fixable_check(config, headline, updated_content:, apply_messages:, **attributes)
        build_check(
          config,
          status: :fixable,
          headline: headline,
          updated_content: updated_content,
          apply_messages: apply_messages,
          **attributes
        )
      end

      def build_check(config, status:, headline:, **attributes)
        Check.new(
          identifier: config.fetch(:identifier),
          category: config.fetch(:category),
          relative_path: config.fetch(:relative_path),
          status: status,
          headline: headline,
          messages: attributes.fetch(:messages, []),
          updated_content: attributes.fetch(:updated_content, nil),
          make_executable: attributes.fetch(:make_executable, false),
          apply_messages: attributes.fetch(:apply_messages, [])
        )
      end

      def absolute_path(relative_path)
        File.join(root, relative_path)
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/AbcSize
  end
end
