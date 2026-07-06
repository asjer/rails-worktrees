module Rails
  module Worktrees
    module Generators
      # Detects common mise.toml setups and suggests loading the worktree-local .env.
      module MiseFollowUp
        FILE_ENCODING = 'UTF-8'.freeze

        private

        def follow_up_notes_text
          return '' unless suggest_mise_env_file?

          [
            '',
            '      Tip:',
            "        Detected #{File.basename(mise_toml_path)}. To auto-load the worktree-local .env when",
            '        you enter a worktree,',
            '        consider adding:',
            '          [env]',
            '          _.file = ".env"'
          ].join("\n")
        end

        def suggest_mise_env_file?
          mise_toml_path && !mise_env_file_configured?
        end

        def mise_env_file_configured?
          return false unless mise_toml_path

          File.read(mise_toml_path, encoding: FILE_ENCODING).match?(/^\s*_.file\s*=\s*["']\.env["']\s*(?:#.*)?\s*$/)
        end

        def mise_toml_path
          @mise_toml_path ||= mise_toml_paths.find { |path| File.file?(path) }
        end

        def mise_toml_paths
          [
            File.join(destination_root, 'mise.toml'),
            File.join(destination_root, '.mise.toml')
          ]
        end
      end
    end
  end
end
