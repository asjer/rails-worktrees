RSpec.describe Rails::Worktrees::InitializerUpdater do
  def patch(content)
    described_class.new(content: content).call
  end

  describe '#call' do
    it 'wraps an unguarded initializer with the current managed initializer format' do
      result = patch(<<~RUBY)
        Rails::Worktrees.configure do |config|
          config.bootstrap_env = false
        end
      RUBY

      expect(result).to be_changed
      expect(result.status).to eq(:updated)
      expect(result.content).to start_with('Rails.application.config.x.rails_worktrees.tap do |config|')
      expect(result.content).to include('  config.bootstrap_env = false')
      expect(result.content).not_to include('Rails::Worktrees.configure do |config|')
    end

    it 'upgrades the older defined? guard to the current managed initializer format' do
      result = patch(<<~RUBY)
        if defined?(Rails::Worktrees)
          Rails::Worktrees.configure do |config|
            config.bootstrap_env = false
          end
        end
      RUBY

      expect(result).to be_changed
      expect(result.content).to start_with('Rails.application.config.x.rails_worktrees.tap do |config|')
      expect(result.content).not_to start_with('if defined?(Rails::Worktrees)')
    end

    it 'does not treat a partially present older guard as already updated' do
      result = patch(<<~RUBY)
        if Gem.loaded_specs.key?('rails-worktrees') &&
            Rails::Worktrees.respond_to?(:configure)
          Rails::Worktrees.configure do |config|
            config.bootstrap_env = false
          end
        end
      RUBY

      expect(result).to be_changed
      expect(result.status).to eq(:updated)
      expect(result.content).to start_with('Rails.application.config.x.rails_worktrees.tap do |config|')
      expect(result.content).to include('  config.bootstrap_env = false')
      expect(result.content).not_to include("Gem.loaded_specs.key?('rails-worktrees')")
    end

    it 'is idempotent when the current managed initializer format is already present' do
      content = described_class.default_content

      result = patch(content)

      expect(result).not_to be_changed
      expect(result.status).to eq(:identical)
    end

    it 'skips custom initializers that do not contain a configure block' do
      result = patch("puts 'custom initializer'\n")

      expect(result).not_to be_changed
      expect(result.status).to eq(:skip)
    end

    it 'skips ambiguous initializers with extra code outside the configure block' do
      result = patch(<<~RUBY)
        puts 'before'

        Rails::Worktrees.configure do |config|
          config.bootstrap_env = false
        end
      RUBY

      expect(result).not_to be_changed
      expect(result.status).to eq(:skip)
    end

    it 'fills an empty initializer with the managed default content' do
      result = patch('')

      expect(result).to be_changed
      expect(result.status).to eq(:updated)
      expect(result.content).to eq(described_class.default_content)
    end

    it 'keeps the comment indentation stable when upgrading the old managed format' do
      result = patch(<<~RUBY)
        if Gem.loaded_specs.key?('rails-worktrees') &&
            defined?(Rails::Worktrees) &&
            Rails::Worktrees.respond_to?(:configure)
          Rails::Worktrees.configure do |config|
            # config.used_names_file = File.join(
            #   ENV.fetch('XDG_STATE_HOME', File.expand_path('~/.local/state')),
            #   'rails-worktrees',
            #   'used-names.tsv'
            # )
          end
        end
      RUBY

      expect(result.content).to include(<<~RUBY.chomp)
        Rails.application.config.x.rails_worktrees.tap do |config|
          # config.used_names_file = File.join(
          #   ENV.fetch('XDG_STATE_HOME', File.expand_path('~/.local/state')),
          #   'rails-worktrees',
          #   'used-names.tsv'
          # )
        end
      RUBY
    end

    it 'fills a whitespace-only initializer with the managed default content' do
      result = patch("  \n\t\n")

      expect(result).to be_changed
      expect(result.status).to eq(:updated)
      expect(result.content).to eq(described_class.default_content)
    end
  end
end
