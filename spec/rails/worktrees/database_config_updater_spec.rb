# frozen_string_literal: true

RSpec.describe Rails::Worktrees::DatabaseConfigUpdater do
  def patch(content)
    described_class.new(content: content).call
  end

  def suffix
    "<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>"
  end

  describe '#call' do
    it 'patches a single database development and test config' do
      result = patch("development:\n  database: demo_app_development\n\ntest:\n  database: demo_app_test\n")

      expect(result).to be_changed
      expect(result.content).to include("demo_app_development#{suffix}")
      expect(result.content).to include("demo_app_test#{suffix}")
    end

    it 'patches common multi-database role names' do
      yaml = <<~YAML
        development:
          primary:
            database: demo_app_development_primary
          cache:
            database: demo_app_development_cache

        test:
          primary:
            database: demo_app_test_primary
      YAML

      result = patch(yaml)

      expect(result).to be_changed
      expect(result.content).to include("demo_app_development#{suffix}_primary")
      expect(result.content).to include("demo_app_development#{suffix}_cache")
      expect(result.content).to include("demo_app_test#{suffix}_primary")
    end

    it 'patches default Rails sqlite database file paths' do
      result = patch(
        "development:\n  database: storage/development.sqlite3\n\ntest:\n  database: storage/test.sqlite3\n"
      )

      expect(result).to be_changed
      expect(result.content).to include("storage/development#{suffix}.sqlite3")
      expect(result.content).to include("storage/test#{suffix}.sqlite3")
    end

    it 'is idempotent when the suffix already exists' do
      result = patch("development:\n  database: demo_app_development#{suffix}\n")

      expect(result).not_to be_changed
      expect(result.messages).to include('Development/test database names already include WORKTREE_DATABASE_SUFFIX.')
    end

    it 'reports unsupported custom database values' do
      result = patch("development:\n  database: <%= ENV.fetch('APP_DATABASE_NAME') %>\n")

      expect(result).not_to be_changed
      expect(result.messages.last).to include('Could not safely rewrite config/database.yml')
    end
  end
end
