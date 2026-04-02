module Rails
  module Worktrees
    # Hooks install guidance into Rails boot when the generator has not run yet.
    class Railtie < ::Rails::Railtie
      initializer 'rails_worktrees.installation_hint' do
        Rails::Worktrees.warn_about_missing_installation
      end

      initializer 'rails_worktrees.apply_application_config', after: :load_config_initializers do |app|
        Rails::Worktrees.apply_application_configuration(app.config.x.rails_worktrees)
      end
    end
  end
end
