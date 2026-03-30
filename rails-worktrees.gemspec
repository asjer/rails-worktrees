require_relative 'lib/rails/worktrees/version'

Gem::Specification.new do |spec|
  spec.name = 'rails-worktrees'
  spec.version = Rails::Worktrees::VERSION
  spec.authors = ['Asjer Querido']
  spec.email = ['asjer@johnyontherun.com']

  spec.summary = 'Helpers for managing Rails application git worktrees.'
  spec.description = 'Rails::Worktrees is a Ruby gem intended to support working with ' \
                     'git worktrees in Rails development workflows.'
  spec.homepage = 'https://github.com/asjer/rails-worktrees'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/asjer/rails-worktrees'
  spec.metadata['changelog_uri'] = 'https://github.com/asjer/rails-worktrees/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.post_install_message = <<~MSG

    ============================================
      Thank you for installing rails-worktrees! \u{1F389}

      Run the installer:
        $ bin/rails generate worktrees:install

      Docs: https://github.com/asjer/rails-worktrees
    ============================================

  MSG

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.end_with?('.gem') ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'railties', '>= 7.1', '< 8.2'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
