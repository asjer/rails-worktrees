require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe Rails::Worktrees::CredentialKeyLinker do
  subject(:linker) do
    described_class.new(
      target_dir: target_dir,
      peer_roots: peer_roots,
      configuration: configuration
    )
  end

  let(:tmpdir) { Dir.mktmpdir('credential-key-linker-spec') }
  let(:target_dir) { File.join(tmpdir, 'target') }
  let(:peer_dir)   { File.join(tmpdir, 'peer') }

  let(:configuration) do
    Rails::Worktrees::Configuration.new.tap do |c|
      c.link_credential_keys = true
      c.link_test_credential_key = false
      c.link_production_credential_key = false
    end
  end

  let(:peer_roots) { [peer_dir] }

  around do |example|
    FileUtils.mkdir_p(target_dir)
    FileUtils.mkdir_p(peer_dir)
    example.run
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  def write_peer_key(name)
    dir = File.join(peer_dir, 'config/credentials')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.key"), 'secret')
    File.join(dir, "#{name}.key")
  end

  def target_key_path(name)
    File.join(target_dir, 'config/credentials', "#{name}.key")
  end

  describe '#call' do
    context 'when peer has a development.key' do
      before { write_peer_key('development') }

      it 'creates a symlink in the target worktree' do
        linker.call

        expect(File.symlink?(target_key_path('development'))).to be(true)
        expect(File.exist?(target_key_path('development'))).to be(true)
      end

      it 'returns a message about the linked key' do
        result = linker.call

        expect(result.messages).to include(include('Linked development.key →'))
      end

      it 'does not link test or production keys by default' do
        write_peer_key('test')
        write_peer_key('production')
        linker.call

        expect(File.symlink?(target_key_path('test'))).to be(false)
        expect(File.symlink?(target_key_path('production'))).to be(false)
      end
    end

    context 'when dry_run: true' do
      before { write_peer_key('development') }

      it 'does not create a symlink' do
        linker.call(dry_run: true)

        expect(File.symlink?(target_key_path('development'))).to be(false)
      end

      it 'returns a "Would link" message' do
        result = linker.call(dry_run: true)

        expect(result.messages).to include(include('Would link development.key →'))
      end
    end

    context 'when development.key already exists as a symlink' do
      before do
        source = write_peer_key('development')
        dest_dir = File.join(target_dir, 'config/credentials')
        FileUtils.mkdir_p(dest_dir)
        File.symlink(source, File.join(dest_dir, 'development.key'))
      end

      it 'does not overwrite the existing symlink' do
        expect { linker.call }.not_to raise_error

        result = linker.call
        expect(result.messages).to include(include('already linked'))
      end
    end

    context 'when development.key is a broken symlink' do
      before do
        dest_dir = File.join(target_dir, 'config/credentials')
        FileUtils.mkdir_p(dest_dir)
        File.symlink(File.join(tmpdir, 'missing.key'), File.join(dest_dir, 'development.key'))
        write_peer_key('development')
      end

      it 'relinks the broken symlink to a valid peer key' do
        result = linker.call

        expect(File.symlink?(target_key_path('development'))).to be(true)
        expect(File.exist?(target_key_path('development'))).to be(true)
        expect(result.messages).to include(include('Relinked development.key →'))
      end

      it 'reports a dry-run relink without changing the symlink' do
        original_target = File.readlink(target_key_path('development'))

        result = linker.call(dry_run: true)

        expect(File.readlink(target_key_path('development'))).to eq(original_target)
        expect(result.messages).to include(include('Would relink development.key →'))
      end
    end

    context 'when development.key already exists as a real file' do
      before do
        write_peer_key('development')
        dest_dir = File.join(target_dir, 'config/credentials')
        FileUtils.mkdir_p(dest_dir)
        File.write(File.join(dest_dir, 'development.key'), 'local-key')
      end

      it 'does not overwrite the real file' do
        linker.call

        expect(File.symlink?(target_key_path('development'))).to be(false)
        expect(File.read(target_key_path('development'))).to eq('local-key')
      end

      it 'returns a message about leaving it as-is' do
        result = linker.call

        expect(result.messages).to include(include('already exists'))
      end
    end

    context 'when no peer has the key' do
      it 'returns a warning message' do
        result = linker.call

        expect(result.messages).to include(include('Could not find source for development.key'))
        expect(File.symlink?(target_key_path('development'))).to be(false)
      end
    end

    context 'when test and production key linking is enabled' do
      before do
        configuration.link_credential_keys = true
        configuration.link_test_credential_key = true
        configuration.link_production_credential_key = true
        write_peer_key('development')
        write_peer_key('test')
        write_peer_key('production')
      end

      it 'links all three keys' do
        linker.call

        expect(File.symlink?(target_key_path('development'))).to be(true)
        expect(File.symlink?(target_key_path('test'))).to be(true)
        expect(File.symlink?(target_key_path('production'))).to be(true)
      end
    end

    context 'when link_credential_keys is false' do
      before do
        configuration.link_credential_keys = false
        write_peer_key('development')
      end

      it 'does not link any key' do
        linker.call

        expect(File.symlink?(target_key_path('development'))).to be(false)
      end

      it 'returns no messages' do
        result = linker.call

        expect(result.messages).to be_empty
      end
    end

    context 'when target_dir is also in peer_roots' do
      let(:peer_roots) { [target_dir, peer_dir] }

      before do
        # Place a key inside target_dir/config/credentials to verify it is skipped
        target_peer_key = File.join(target_dir, 'config/credentials', 'development.key')
        FileUtils.mkdir_p(File.dirname(target_peer_key))
        # do NOT write it so we can confirm self is skipped and fallback to real peer
        write_peer_key('development')
      end

      it 'skips itself and links from the peer' do
        result = linker.call

        expect(result.messages).to include(match(/Linked development\.key → .*peer/))
      end
    end
  end
end
