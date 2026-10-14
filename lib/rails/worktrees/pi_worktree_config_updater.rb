require 'json'
require_relative 'pi_worktree_config_path'

module Rails
  module Worktrees
    # Safely merges the bin/wt setup hook into the pi-worktree extension's .pi/worktree.json.
    class PiWorktreeConfigUpdater
      Result = Struct.new(:content, :changed, :status, :messages) do
        def changed?
          changed
        end
      end

      RELATIVE_PATH = PiWorktreeConfigPath::RELATIVE_PATH
      SETUP_COMMAND = 'bin/wt setup'.freeze
      # Horizontal whitespace only: a newline would make the shell run two separate commands.
      SETUP_COMMAND_PATTERN = %r{\A[ \t]*(?:\./)?bin/wt[ \t]+setup[ \t]*\z}

      def self.configured?(content)
        return false if content.nil? || !content.valid_encoding?

        config = JSON.parse(content)
        config.is_a?(Hash) && setup_hook?(config['postCreate'])
      rescue JSON::ParserError
        false
      end

      def self.setup_hook?(commands)
        return false unless commands.is_a?(Array)

        commands.any? { |command| command.is_a?(String) && command.match?(SETUP_COMMAND_PATTERN) }
      end

      def initialize(content:)
        @content = content
      end

      def call
        config = parse_config
        return config if config.is_a?(Result)

        conflict = conflict_message(config)
        return conflict_result(conflict) if conflict

        merge_setup_hook(config)
      end

      private

      def parse_config
        return {} if @content.nil?
        unless @content.valid_encoding?
          return conflict_result("#{RELATIVE_PATH} is not valid UTF-8; leaving it unchanged.")
        end
        return {} if @content.strip.empty?

        config = JSON.parse(@content)
        return config if config.is_a?(Hash)

        conflict_result("#{RELATIVE_PATH} must contain a JSON object; leaving it unchanged.")
      rescue JSON::ParserError => e
        conflict_result("#{RELATIVE_PATH} is not valid JSON (#{e.message.lines.first.strip}); leaving it unchanged.")
      end

      def conflict_message(config)
        if config.key?('linkEnvFiles') && config['linkEnvFiles'] != false
          return [
            "#{RELATIVE_PATH} sets \"linkEnvFiles\": #{JSON.generate(config['linkEnvFiles'])}, so pi-worktree " \
            "would symlink the main checkout's .env into new worktrees before bin/wt setup runs.",
            'Set "linkEnvFiles": false yourself to give each worktree its own DEV_PORT and ' \
            'WORKTREE_DATABASE_SUFFIX, then rerun this command; the file was left unchanged.'
          ]
        end

        return if !config.key?('postCreate') || string_list?(config['postCreate'])

        "#{RELATIVE_PATH} postCreate must be a list of shell commands; leaving it unchanged."
      end

      def merge_setup_hook(config)
        updated = config.dup
        messages = [add_setup_hook(updated), disable_env_file_linking(updated)].compact
        return identical_result if messages.empty?

        Result.new("#{JSON.pretty_generate(ordered_new_config(config, updated))}\n", true, :updated, messages)
      end

      def add_setup_hook(config)
        return if self.class.setup_hook?(config['postCreate'])

        config['postCreate'] = Array(config['postCreate']) + [SETUP_COMMAND]
        "Added \"#{SETUP_COMMAND}\" to postCreate in #{RELATIVE_PATH}."
      end

      def disable_env_file_linking(config)
        return if config.key?('linkEnvFiles')

        config['linkEnvFiles'] = false
        "Disabled linkEnvFiles in #{RELATIVE_PATH} so each worktree keeps its own .env."
      end

      # Fresh configs list linkEnvFiles first so the safety switch is visible above the hooks.
      def ordered_new_config(original, updated)
        return updated unless original.empty?

        { 'linkEnvFiles' => updated['linkEnvFiles'], 'postCreate' => updated['postCreate'] }
      end

      def string_list?(value)
        value.is_a?(Array) && value.all?(String)
      end

      def identical_result
        Result.new(@content, false, :identical,
                   ["#{RELATIVE_PATH} already runs bin/wt setup with env-file linking disabled."])
      end

      def conflict_result(messages)
        Result.new(@content, false, :conflict, Array(messages))
      end
    end
  end
end
