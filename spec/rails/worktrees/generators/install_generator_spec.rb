require 'fileutils'
require 'tmpdir'

require 'rails/worktrees'
require 'generators/worktrees/install/install_generator'

RSpec.describe Worktrees::Generators::InstallGenerator do
  let(:tmpdir) { Dir.mktmpdir('rails-worktrees-generator-spec') }

  around do |example|
    FileUtils.mkdir_p(File.join(tmpdir, 'config'))
    write_database_yml(
      "development:\n  database: demo_app_development_primary\n\ntest:\n  database: demo_app_test_primary\n"
    )
    example.run
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  def write_database_yml(content)
    File.write(File.join(tmpdir, 'config/database.yml'), content)
  end

  def read_database_yml
    File.read(File.join(tmpdir, 'config/database.yml'))
  end

  def read_initializer
    File.read(File.join(tmpdir, 'config/initializers/rails_worktrees.rb'))
  end

  def read_procfile_worktree_example
    File.read(File.join(tmpdir, 'Procfile.dev.worktree.example'))
  end

  def read_procfile_dev
    File.read(File.join(tmpdir, 'Procfile.dev'))
  end

  def browser_wrapper_path
    File.join(tmpdir, 'bin/ob')
  end

  def read_puma_config
    File.read(File.join(tmpdir, 'config/puma.rb'))
  end

  def write_mise_toml(content)
    File.write(File.join(tmpdir, 'mise.toml'), content)
  end

  def write_dot_mise_toml(content)
    File.write(File.join(tmpdir, '.mise.toml'), content)
  end

  def write_procfile_dev(content)
    File.write(File.join(tmpdir, 'Procfile.dev'), content)
  end

  def write_puma_config(content)
    File.write(File.join(tmpdir, 'config/puma.rb'), content)
  end

  def expect_standard_procfile_dev
    expect(read_procfile_dev).to eq(<<~PROCFILE)
      web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}
      js: yarn build --watch
    PROCFILE
  end

  def expect_standard_mise_toml(path = 'mise.toml')
    expect(File.read(File.join(tmpdir, path))).to eq(<<~TOML)
      [tools]
      ruby = "3.4.8"

      [env]
      _.file = ".env"
    TOML
  end

  def expect_standard_puma_config
    expect(read_puma_config).to eq(<<~RUBY)
      # Specifies the `port` that Puma will listen on to receive requests; default is 3000.
      port ENV['DEV_PORT'] || ENV.fetch('PORT', 3000)
    RUBY
  end

  def prepare_yolo_configured_files
    write_procfile_dev(<<~PROCFILE)
      web: bin/rails server
      js: yarn build --watch
    PROCFILE
    write_mise_toml(<<~TOML)
      [tools]
      ruby = "3.4.8"
    TOML
    write_puma_config(<<~RUBY)
      # Specifies the `port` that Puma will listen on to receive requests; default is 3000.
      port ENV.fetch("PORT", 3000)
    RUBY
  end

  def run_generator(*args)
    described_class.start(args, destination_root: tmpdir)
  end

  def capture_generator_output(*args)
    output = +''
    allow(described_class).to receive(:new).and_wrap_original do |original, *generator_args, **kwargs|
      generator = original.call(*generator_args, **kwargs)
      allow(generator).to receive(:say).and_wrap_original do |orig_say, *say_args|
        output << say_args.first.to_s << "\n"
        orig_say.call(*say_args)
      end
      generator
    end
    run_generator(*args)
    output
  end

  def suffix
    "<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>"
  end

  it 'installs bin/wt, the initializer, and patches config/database.yml' do
    run_generator

    expect(File.exist?(File.join(tmpdir, 'bin/wt'))).to be(true)
    expect(File.exist?(browser_wrapper_path)).to be(false)
    expect(File.exist?(File.join(tmpdir, 'config/initializers/rails_worktrees.rb'))).to be(true)
    expect(File.exist?(File.join(tmpdir, 'Procfile.dev.worktree.example'))).to be(true)
    expect(read_database_yml).to include("demo_app_development#{suffix}_primary")
    expect(read_database_yml).to include("demo_app_test#{suffix}_primary")
  end

  it 'leaves the new sibling-directory default implicit in the initializer' do
    run_generator

    expect(read_initializer.lines.first).not_to match(/\A#\s*frozen_string_literal:/)
    expect(read_initializer).to start_with(<<~RUBY)
      Rails.application.config.x.rails_worktrees.tap do |config|
    RUBY
    expect(read_initializer).to include('By default, worktrees go in a sibling "<project>.worktrees" directory.')
    expect(read_initializer).to include('# config.bootstrap_env = false')
    expect(read_initializer).to include('# config.dev_port_range = 3000..3999')
    expect(read_initializer.rstrip).to end_with('end')
    expect(read_initializer).not_to include("config.workspace_root = File.expand_path('~/Sites/conductor/workspaces')")
  end

  it 'creates a Procfile.dev example with the DEV_PORT-aware web entry' do
    run_generator

    expect(read_procfile_worktree_example)
      .to include('web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}')
  end

  describe '--yolo' do
    it 'creates bin/ob for browser shortcuts' do
      run_generator('--yolo')

      expect(File.exist?(browser_wrapper_path)).to be(true)
      expect(File.executable?(browser_wrapper_path)).to be(true)
    end

    it 'does not create Procfile.dev.worktree.example' do
      run_generator('--yolo')

      expect(File.exist?(File.join(tmpdir, 'Procfile.dev.worktree.example'))).to be(false)
    end

    it 'rewrites an existing Procfile.dev web entry with the standard DEV_PORT-aware command' do
      write_procfile_dev(<<~PROCFILE)
        web: bin/rails server
        js: yarn build --watch
      PROCFILE

      run_generator('--yolo')

      expect(File.exist?(File.join(tmpdir, 'Procfile.dev.worktree.example'))).to be(false)
      expect(read_procfile_dev).to eq(<<~PROCFILE)
        web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}
        js: yarn build --watch
      PROCFILE
    end

    it 'inserts _.file into an existing [env] section in mise.toml' do
      write_mise_toml(<<~TOML)
        [tools]
        ruby = "3.4.8"

        [env]
        _.path = ["{{cwd}}/bin"]
      TOML

      run_generator('--yolo')

      expect(File.read(File.join(tmpdir, 'mise.toml'))).to eq(<<~TOML)
        [tools]
        ruby = "3.4.8"

        [env]
        _.path = ["{{cwd}}/bin"]
        _.file = ".env"
      TOML
    end

    it 'rewrites the current Rails puma port line to prefer DEV_PORT' do
      write_puma_config(<<~RUBY)
        # Specifies the `port` that Puma will listen on to receive requests; default is 3000.
        port ENV.fetch("PORT", 3000)
      RUBY

      run_generator('--yolo')

      expect_standard_puma_config
    end

    it 'rewrites older supported Rails puma port variants to prefer DEV_PORT' do
      write_puma_config(<<~RUBY)
        # Puma can serve each request in a thread from an internal thread pool.
        port ENV.fetch("PORT") { 3000 }
      RUBY

      run_generator('--yolo')

      expect(read_puma_config).to eq(<<~RUBY)
        # Puma can serve each request in a thread from an internal thread pool.
        port ENV['DEV_PORT'] || ENV.fetch('PORT', 3000)
      RUBY
    end

    it 'adds a new [env] section to .mise.toml when needed' do
      write_dot_mise_toml(<<~TOML)
        [tools]
        ruby = "3.4.8"
      TOML

      run_generator('--yolo')

      expect_standard_mise_toml('.mise.toml')
    end

    it 'reports skips instead of creating Procfile.dev or mise config files' do
      output = capture_generator_output('--yolo')

      expect(File.exist?(File.join(tmpdir, 'Procfile.dev'))).to be(false)
      expect(File.exist?(File.join(tmpdir, 'config/puma.rb'))).to be(false)
      expect(File.exist?(File.join(tmpdir, 'mise.toml'))).to be(false)
      expect(File.exist?(File.join(tmpdir, '.mise.toml'))).to be(false)
      expect(output).to include('Skipped Procfile.dev yolo update because the file does not exist yet.')
      expect(output).to include('Skipped config/puma.rb yolo update because the file does not exist yet.')
      expect(output).to include('Skipped mise yolo update because no supported mise config file was found.')
    end

    it 'is idempotent on rerun once Procfile.dev and mise.toml are already configured' do
      prepare_yolo_configured_files

      run_generator('--yolo')
      output = capture_generator_output('--yolo')

      expect_standard_procfile_dev
      expect_standard_mise_toml
      expect_standard_puma_config
      expect(output).to include('Procfile.dev already uses the DEV_PORT-aware web entry.')
      expect(output).to include('config/puma.rb already uses DEV_PORT-aware port binding.')
      expect(output).to include('mise.toml already loads .env from [env].')
    end
  end

  describe '--browser' do
    it 'creates bin/ob without enabling yolo follow-ups' do
      run_generator('--browser')

      expect(File.exist?(browser_wrapper_path)).to be(true)
      expect(File.executable?(browser_wrapper_path)).to be(true)
      expect(File.exist?(File.join(tmpdir, 'Procfile.dev.worktree.example'))).to be(true)
    end
  end

  it 'writes the conductor workspace override when requested' do
    run_generator('--conductor')

    expect(read_initializer).to start_with('Rails.application.config.x.rails_worktrees.tap do |config|')
    expect(read_initializer).to include("config.workspace_root = File.expand_path('~/Sites/conductor/workspaces')")
  end

  it 'patches a fresh Rails sqlite database.yml layout' do
    write_database_yml(
      "development:\n  database: storage/development.sqlite3\n\ntest:\n  database: storage/test.sqlite3\n"
    )
    run_generator

    expect(read_database_yml).to include("storage/development#{suffix}.sqlite3")
    expect(read_database_yml).to include("storage/test#{suffix}.sqlite3")
  end

  describe 'follow-up message' do
    it 'displays a bordered follow-up with installed files and next steps' do
      output = capture_generator_output

      expect(output).to include('============================================')
      expect(output).to include('rails-worktrees installed successfully!')
      expect(output).to include('bin/wt')
      expect(output).not_to include('bin/ob')
      expect(output).to include('config/initializers/rails_worktrees.rb')
      expect(output).to include('Procfile.dev.worktree.example')
      expect(output).to include('$ bin/wt')
      expect(output).to include('$ bin/wt my-feature')
    end

    it 'lists bin/ob and browser examples when --browser is used' do
      output = capture_generator_output('--browser')

      expect(output).to include('bin/ob')
      expect(output).to include('$ bin/ob')
      expect(output).to include('$ bin/ob contact')
      expect(output).to include("$ bin/ob --print-url '?from=nav'")
    end

    it 'lists bin/ob and browser examples when --yolo is used' do
      output = capture_generator_output('--yolo')

      expect(output).to include('bin/ob')
      expect(output).to include('$ bin/ob')
      expect(output).to include('$ bin/ob contact')
      expect(output).to include("$ bin/ob --print-url '?from=nav'")
    end

    it 'includes a database note when database.yml was updated' do
      output = capture_generator_output

      expect(output).to include('config/database.yml (updated with WORKTREE_DATABASE_SUFFIX)')
    end

    it 'suggests loading .env automatically when mise.toml is present without _.file' do
      write_mise_toml(<<~TOML)
        [tools]
        ruby = "3.4.8"

        [env]
        _.path = ["{{cwd}}/bin"]
      TOML

      output = capture_generator_output

      expect(output).to include('Detected mise.toml.')
      expect(output).to include('_.file = ".env"')
    end

    it 'suggests loading .env automatically when .mise.toml is present without _.file' do
      write_dot_mise_toml(<<~TOML)
        [tools]
        ruby = "3.4.8"
      TOML

      output = capture_generator_output

      expect(output).to include('Detected .mise.toml.')
      expect(output).to include('_.file = ".env"')
    end

    it 'suggests making config/puma.rb prefer DEV_PORT when it uses the default port binding' do
      write_puma_config(<<~RUBY)
        # Specifies the `port` that Puma will listen on to receive requests; default is 3000.
        port ENV.fetch("PORT", 3000)
      RUBY

      output = capture_generator_output

      expect(output).to include('Detected config/puma.rb.')
      expect(output).to include("port ENV['DEV_PORT'] || ENV.fetch('PORT', 3000)")
    end

    it 'omits the puma hint when config/puma.rb already prefers DEV_PORT' do
      write_puma_config(<<~RUBY)
        # Specifies the `port` that Puma will listen on to receive requests; default is 3000.
        port ENV['DEV_PORT'] || ENV.fetch('PORT', 3000)
      RUBY

      output = capture_generator_output

      expect(output).not_to include('Detected config/puma.rb.')
    end

    it 'omits the mise hint when mise.toml already loads .env' do
      write_mise_toml(<<~TOML)
        [tools]
        ruby = "3.4.8"

        [env]
        _.path = ["{{cwd}}/bin"]
        _.file = ".env"
      TOML

      output = capture_generator_output

      expect(output).not_to include('Detected mise.toml.')
    end

    it 'omits the mise hint when mise.toml loads .env with an inline comment' do
      write_mise_toml(<<~TOML)
        [tools]
        ruby = "3.4.8"

        [env]
        _.path = ["{{cwd}}/bin"]
        _.file = ".env" # load worktree env
      TOML

      output = capture_generator_output

      expect(output).not_to include('Detected mise.toml.')
    end

    it 'omits the mise hint after --yolo updates mise.toml automatically' do
      write_mise_toml(<<~TOML)
        [tools]
        ruby = "3.4.8"
      TOML

      output = capture_generator_output('--yolo')

      expect(output).not_to include('Detected mise.toml.')
      expect(output).to include('Configured mise.toml to load .env from [env].')
    end

    it 'omits the puma hint after --yolo updates config/puma.rb automatically' do
      write_puma_config(<<~RUBY)
        # Specifies the `port` that Puma will listen on to receive requests; default is 3000.
        port ENV.fetch("PORT", 3000)
      RUBY

      output = capture_generator_output('--yolo')

      expect(output).not_to include('Detected config/puma.rb.')
      expect(output).to include('Updated config/puma.rb to prefer DEV_PORT before PORT.')
    end

    it 'does not list Procfile.dev.worktree.example as installed in yolo mode' do
      output = capture_generator_output('--yolo')

      expect(output).not_to include('Procfile.dev.worktree.example')
    end

    it 'omits the database note when database.yml was already identical' do
      write_database_yml(
        "development:\n  database: app_development<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>\n"
      )
      output = capture_generator_output

      expect(output).not_to include('config/database.yml')
    end

    it 'includes a not-found note when database.yml is missing' do
      FileUtils.rm_f(File.join(tmpdir, 'config/database.yml'))
      output = capture_generator_output

      expect(output).to include('config/database.yml was not found')
    end
  end

  describe 'generator metadata' do
    it 'uses the shorter generator namespace' do
      expect(described_class.namespace).to eq('worktrees:install')
    end

    it 'describes the full --yolo follow-up scope' do
      expect(described_class.class_options.fetch(:yolo).description)
        .to eq(
          'Apply common Procfile.dev, config/puma.rb, and mise .env ' \
          'follow-up edits when safe; also generate bin/ob'
        )
    end

    it 'describes the optional browser helper flag' do
      expect(described_class.class_options.fetch(:browser).description)
        .to eq('Generate bin/ob to open localhost:$DEV_PORT routes for this app/worktree')
    end

    it 'points at the shared templates directory' do
      expect(described_class.source_root).to end_with('/lib/generators/rails/worktrees/templates')
    end
  end
end
