module Rails
  module Worktrees
    # Hooks install guidance into Rails boot when the generator has not run yet.
    class Railtie < ::Rails::Railtie
      initializer 'rails_worktrees.installation_hint' do
        Rails::Worktrees.warn_about_missing_installation
      end
    end
  end
end
