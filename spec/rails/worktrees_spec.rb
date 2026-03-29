# frozen_string_literal: true

RSpec.describe Rails::Worktrees do
  after do
    described_class.reset_configuration!
  end

  it 'has a version number' do
    expect(Rails::Worktrees::VERSION).not_to be_nil
  end

  it 'defines an error class' do
    expect(Rails::Worktrees::Error).to be < StandardError
  end

  it 'exposes a configuration object' do
    expect(described_class.configuration).to be_a(Rails::Worktrees::Configuration)
  end

  it 'yields configuration updates' do
    described_class.configure do |config|
      config.branch_prefix = '🌿'
    end

    expect(described_class.configuration.branch_prefix).to eq('🌿')
  end

  it 'returns the configuration object from configure' do
    returned_configuration = described_class.configure do |config|
      config.branch_prefix = '🌿'
      :ignored_block_value
    end

    expect(returned_configuration).to be(described_class.configuration)
  end
end
