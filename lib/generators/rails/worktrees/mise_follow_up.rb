# frozen_string_literal: true

module Rails
  module Worktrees
    module Generators
      # Detects common mise.toml setups and suggests loading the worktree-local .env.
      module MiseFollowUp
        private

        def follow_up_notes_text
          return '' unless suggest_mise_env_file?

          [
            '',
            '      Tip:',
            '        Detected mise.toml. To auto-load the worktree-local .env when you enter a worktree,',
            '        consider adding:',
            '          [env]',
            '          _.file = ".env"'
          ].join("\n")
        end

        def suggest_mise_env_file?
          File.file?(mise_toml_path) && !mise_env_file_configured?
        end

        def mise_env_file_configured?
          File.read(mise_toml_path).match?(/^\s*_.file\s*=\s*["']\.env["']\s*$/)
        end

        def mise_toml_path
          File.join(destination_root, 'mise.toml')
        end
      end
    end
  end
end
