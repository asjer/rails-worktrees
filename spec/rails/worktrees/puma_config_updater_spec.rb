RSpec.describe Rails::Worktrees::PumaConfigUpdater do
  def patch(content)
    described_class.new(content: content).call
  end

  describe '#call' do
    it 'rewrites supported port lines and preserves inline comments' do
      result = patch("port ENV.fetch(\"PORT\", 3000) # main app port\n")

      expect(result).to be_changed
      expect(result.status).to eq(:updated)
      expect(result.content).to eq("port ENV['DEV_PORT'] || ENV.fetch('PORT', 3000) # main app port\n")
    end

    it 'does not treat a trailing DEV_PORT comment as already configured' do
      result = patch("port ENV.fetch(\"PORT\", 3000) # switch this to DEV_PORT later\n")

      expect(result).to be_changed
      expect(result.content).to eq("port ENV['DEV_PORT'] || ENV.fetch('PORT', 3000) # switch this to DEV_PORT later\n")
    end

    it 'treats actual DEV_PORT bindings as already configured' do
      result = patch("port ENV.fetch(\"DEV_PORT\", 3000)\n")

      expect(result).not_to be_changed
      expect(result.status).to eq(:identical)
      expect(result.messages).to include('config/puma.rb already uses DEV_PORT-aware port binding.')
    end
  end
end
