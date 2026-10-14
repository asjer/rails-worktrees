require 'fileutils'
require 'tmpdir'

RSpec.describe Rails::Worktrees::PiWorktreeConfigPath do
  describe '.conflict' do
    let(:root) { Dir.mktmpdir('rails-worktrees-pi-path') }
    let(:outside) { Dir.mktmpdir('rails-worktrees-pi-outside') }

    after { FileUtils.rm_rf([root, outside]) }

    def pi_path(*parts) = File.join(root, '.pi', *parts)

    it 'accepts a missing or regular config file inside the root' do
      expect(described_class.conflict(root)).to be_nil
      FileUtils.mkdir_p(pi_path)
      File.write(pi_path('worktree.json'), '{}')
      expect(described_class.conflict(root)).to be_nil
    end

    it 'rejects a symlinked config file' do
      File.write(File.join(outside, 'worktree.json'), '{}')
      FileUtils.mkdir_p(pi_path)
      File.symlink(File.join(outside, 'worktree.json'), pi_path('worktree.json'))

      expect(described_class.conflict(root)).to eq('is a symlink')
    end

    it 'rejects a config path that is not a regular file' do
      FileUtils.mkdir_p(pi_path('worktree.json'))

      expect(described_class.conflict(root)).to eq('is not a regular file')
    end

    it 'rejects a .pi entry that is a regular file or a broken symlink' do
      File.write(pi_path, 'not a directory')
      expect(described_class.conflict(root)).to eq('cannot be created because .pi is not a directory')

      FileUtils.rm_f(pi_path)
      File.symlink(File.join(outside, 'missing'), pi_path)
      expect(described_class.conflict(root)).to eq('cannot be created because .pi is not a directory')
    end

    it 'rejects a .pi directory that resolves outside the root' do
      File.symlink(outside, pi_path)

      expect(described_class.conflict(root)).to eq('resolves outside the app through a symlinked directory')
    end
  end
end
