module Rails
  module Worktrees
    module Generators
      # Detects config/puma.rb setups that should prefer the worktree-local DEV_PORT.
      module PumaFollowUp
        FILE_ENCODING = 'UTF-8'.freeze

        private

        def puma_follow_up_notes_text
          return '' unless suggest_puma_dev_port_update?

          [
            '',
            '      Tip:',
            '        Detected config/puma.rb. To bind Puma to the worktree-local DEV_PORT,',
            '        consider changing the port line to:',
            "          #{::Rails::Worktrees::PumaConfigUpdater::STANDARD_PORT_LINE}"
          ].join("\n")
        end

        def suggest_puma_dev_port_update?
          existing_puma_config_path && puma_update_result.status == :updated
        end

        def puma_update_result
          return missing_puma_update_result unless existing_puma_config_path

          ::Rails::Worktrees::PumaConfigUpdater.new(
            content: File.read(existing_puma_config_path, encoding: FILE_ENCODING)
          ).call
        end

        def missing_puma_update_result
          ::Rails::Worktrees::PumaConfigUpdater::Result.new(nil, false, :skip, [])
        end

        def puma_config_path
          File.join(destination_root, 'config/puma.rb')
        end

        def existing_puma_config_path
          path = puma_config_path
          File.file?(path) ? path : nil
        end
      end
    end
  end
end
