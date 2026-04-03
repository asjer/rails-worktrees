require 'fileutils'

module Rails
  module Worktrees
    # Links credential key files from a sibling worktree into the new worktree.
    class CredentialKeyLinker
      Result = Struct.new(:messages)

      CREDENTIALS_DIR = 'config/credentials'.freeze

      KEY_TYPES = [
        { name: 'development', config_attr: :link_credential_keys },
        { name: 'test',        config_attr: :link_test_credential_key },
        { name: 'production',  config_attr: :link_production_credential_key }
      ].freeze

      def initialize(target_dir:, peer_roots:, configuration:)
        @target_dir = target_dir
        @peer_roots = peer_roots
        @configuration = configuration
      end

      def call(dry_run: false)
        messages = []

        KEY_TYPES.each do |key_type|
          next unless @configuration.public_send(key_type[:config_attr])

          message = process_key(key_type[:name], dry_run: dry_run)
          messages << message if message
        end

        Result.new(messages)
      end

      private

      def process_key(key_name, dry_run:)
        destination = destination_path_for(key_name)
        existing_message = existing_destination_message(destination, key_name)
        return existing_message if existing_message

        replace_existing_symlink = File.symlink?(destination)
        return "#{key_name}.key already exists; leaving as-is" if File.exist?(destination)

        source = find_source(key_name)
        return "Could not find source for #{key_name}.key" unless source

        link_key(destination, key_name, source, dry_run: dry_run, replace_existing_symlink: replace_existing_symlink)
      end

      def find_source(key_name)
        @peer_roots.each do |peer_root|
          candidate = File.join(peer_root, CREDENTIALS_DIR, "#{key_name}.key")
          next if File.expand_path(peer_root) == File.expand_path(@target_dir)

          return candidate if File.file?(candidate)
        end

        nil
      end

      def destination_path_for(key_name)
        File.join(@target_dir, CREDENTIALS_DIR, "#{key_name}.key")
      end

      def existing_destination_message(destination, key_name)
        return unless File.symlink?(destination) && File.exist?(destination)

        "#{key_name}.key already linked"
      end

      def link_key(destination, key_name, source, dry_run:, replace_existing_symlink: false)
        return dry_run_link_message(key_name, source, replace_existing_symlink) if dry_run

        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.rm_f(destination) if replace_existing_symlink
        File.symlink(source, destination)
        linked_key_message(key_name, source, replace_existing_symlink)
      end

      def dry_run_link_message(key_name, source, replace_existing_symlink)
        verb = replace_existing_symlink ? 'Would relink' : 'Would link'
        "#{verb} #{key_name}.key → #{source}"
      end

      def linked_key_message(key_name, source, replace_existing_symlink)
        verb = replace_existing_symlink ? 'Relinked' : 'Linked'
        "#{verb} #{key_name}.key → #{source}"
      end
    end
  end
end
