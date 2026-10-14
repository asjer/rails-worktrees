require 'json'

RSpec.describe Rails::Worktrees::PiWorktreeConfigUpdater do
  def patch(content)
    described_class.new(content: content).call
  end

  def parsed(result)
    JSON.parse(result.content)
  end

  describe '#call' do
    it 'creates a config that runs bin/wt setup with env-file linking disabled' do
      result = patch(nil)

      expect(result).to be_changed
      expect(result.status).to eq(:updated)
      expect(result.content).to eq(<<~JSON)
        {
          "linkEnvFiles": false,
          "postCreate": [
            "bin/wt setup"
          ]
        }
      JSON
    end

    it 'treats a blank file as an empty config' do
      result = patch("\n")

      expect(result.status).to eq(:updated)
      expect(parsed(result)).to eq('linkEnvFiles' => false, 'postCreate' => ['bin/wt setup'])
    end

    it 'preserves existing settings and custom hooks while appending bin/wt setup' do
      custom = { 'dir' => '.trees', 'branchPrefix' => 'pi/', 'postCreate' => ['npm install'],
                 'preRemove' => ['echo bye'] }
      result = patch(JSON.pretty_generate(custom))

      expect(result.status).to eq(:updated)
      expect(parsed(result)).to eq(
        custom.merge('postCreate' => ['npm install', 'bin/wt setup'], 'linkEnvFiles' => false)
      )
      expect(result.messages).to include(
        'Added "bin/wt setup" to postCreate in .pi/worktree.json.',
        'Disabled linkEnvFiles in .pi/worktree.json so each worktree keeps its own .env.'
      )
    end

    it 'is idempotent and does not add a duplicate hook' do
      first = patch(nil)
      second = patch(first.content)

      expect(second).not_to be_changed
      expect(second.status).to eq(:identical)
      expect(second.content).to eq(first.content)
      expect(second.messages).to eq(
        ['.pi/worktree.json already runs bin/wt setup with env-file linking disabled.']
      )
    end

    it 'recognizes an equivalent existing setup hook' do
      result = patch(%({"linkEnvFiles": false, "postCreate": ["./bin/wt setup --dry-run", "yarn"]}\n))

      expect(result.status).to eq(:identical)
      expect(result.content).to eq(%({"linkEnvFiles": false, "postCreate": ["./bin/wt setup --dry-run", "yarn"]}\n))
    end

    it 'only disables env-file linking when the hook already exists' do
      result = patch(%({"postCreate": ["bin/wt setup"]}))

      expect(result.status).to eq(:updated)
      expect(parsed(result)).to eq('postCreate' => ['bin/wt setup'], 'linkEnvFiles' => false)
      expect(result.messages).to eq(
        ['Disabled linkEnvFiles in .pi/worktree.json so each worktree keeps its own .env.']
      )
    end

    it 'refuses to override an explicit linkEnvFiles: true' do
      content = %({"linkEnvFiles": true, "postCreate": ["npm install"]}\n)
      result = patch(content)

      expect(result).not_to be_changed
      expect(result.status).to eq(:conflict)
      expect(result.content).to eq(content)
      expect(result.messages.join("\n")).to include('"linkEnvFiles": true')
      expect(result.messages.join("\n")).to include('"linkEnvFiles": false')
    end

    it 'refuses to rewrite invalid JSON' do
      result = patch('{ "postCreate": [')

      expect(result).not_to be_changed
      expect(result.status).to eq(:conflict)
      expect(result.messages.first).to include('.pi/worktree.json is not valid JSON')
    end

    it 'refuses to rewrite a non-object document' do
      result = patch('["bin/wt setup"]')

      expect(result.status).to eq(:conflict)
      expect(result.messages.first).to include('must contain a JSON object')
    end

    it 'refuses to rewrite a postCreate value that is not a list of commands' do
      result = patch(%({"postCreate": "npm install"}))

      expect(result.status).to eq(:conflict)
      expect(result.messages.first).to include('postCreate must be a list of shell commands')
    end
  end

  describe '.configured?' do
    it 'detects configs that already contain the bin/wt setup hook' do
      expect(described_class.configured?(%({"postCreate": ["bin/wt setup"]}))).to be(true)
      expect(described_class.configured?(%({"postCreate": ["npm install"]}))).to be(false)
      expect(described_class.configured?('not json')).to be(false)
      expect(described_class.configured?(nil)).to be(false)
    end
  end
end
