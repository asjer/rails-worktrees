# frozen_string_literal: true

RSpec.describe Rails::Worktrees do
  it 'has a version number' do
    expect(Rails::Worktrees::VERSION).not_to be_nil
  end

  it 'defines an error class' do
    expect(Rails::Worktrees::Error).to be < StandardError
  end
end
