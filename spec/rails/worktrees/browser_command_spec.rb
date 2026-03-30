require 'fileutils'
require 'stringio'
require 'tmpdir'

RSpec.describe Rails::Worktrees::BrowserCommand do
  let(:tmpdir) { Dir.mktmpdir('rails-worktrees-browser-command-spec') }

  around do |example|
    File.write(File.join(tmpdir, 'Gemfile'), "source 'https://rubygems.org'\n")
    example.run
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  def write_env(content)
    File.write(File.join(tmpdir, '.env'), content)
  end

  def build_command(argv: [], io: {}, env: {}, cwd: tmpdir, host_os: 'darwin')
    described_class.new(
      argv: argv,
      io: { stdin: StringIO.new, stdout: StringIO.new, stderr: StringIO.new }.merge(io),
      env: { 'PATH' => ENV.fetch('PATH', '') }.merge(env),
      cwd: cwd,
      host_os: host_os
    )
  end

  it 'opens localhost using DEV_PORT from the app .env' do
    write_env("DEV_PORT=3456\n")
    out = StringIO.new
    command = build_command(io: { stdout: out })

    allow(command).to receive(:command_available?).with('open').and_return(true)
    allow(command).to receive(:run_opener).with('open', 'http://localhost:3456/').and_return(true)

    expect(command.run).to eq(0)
    expect(out.string).to include('🌐 Opening http://localhost:3456/')
  end

  it 'normalizes route arguments onto localhost paths' do
    write_env("DEV_PORT=4567\n")
    out = StringIO.new
    command = build_command(argv: ['contact?from=nav#top'], io: { stdout: out })

    allow(command).to receive(:command_available?).with('open').and_return(true)
    allow(command).to receive(:run_opener)
      .with('open', 'http://localhost:4567/contact?from=nav#top').and_return(true)

    expect(command.run).to eq(0)
  end

  it 'supports query-only routes on the root path' do
    write_env("DEV_PORT=4567\n")
    command = build_command(argv: ['?from=nav'])

    allow(command).to receive(:command_available?).with('open').and_return(true)
    allow(command).to receive(:run_opener).with('open', 'http://localhost:4567/?from=nav').and_return(true)

    expect(command.run).to eq(0)
  end

  it 'prefers the .env DEV_PORT over the shell DEV_PORT' do
    write_env("DEV_PORT=3456\n")
    command = build_command(argv: ['contact'], env: { 'DEV_PORT' => '6789' })

    allow(command).to receive(:command_available?).with('open').and_return(true)
    allow(command).to receive(:run_opener).with('open', 'http://localhost:3456/contact').and_return(true)

    expect(command.run).to eq(0)
  end

  it 'falls back to ENV DEV_PORT when no .env exists' do
    err = StringIO.new
    command = build_command(argv: ['contact'], io: { stderr: err }, env: { 'DEV_PORT' => '6789' })

    allow(command).to receive(:command_available?).with('open').and_return(true)
    allow(command).to receive(:run_opener).with('open', 'http://localhost:6789/contact').and_return(true)

    expect(command.run).to eq(0)
    expect(err.string).to include(
      "Info: #{File.join(tmpdir, '.env')} was not found; falling back to ENV['DEV_PORT']=6789."
    )
  end

  it 'falls back to port 3000 when no DEV_PORT is configured' do
    err = StringIO.new
    command = build_command(argv: ['contact'], io: { stderr: err })

    allow(command).to receive(:command_available?).with('open').and_return(true)
    allow(command).to receive(:run_opener).with('open', 'http://localhost:3000/contact').and_return(true)

    expect(command.run).to eq(0)
    expect(err.string).to include(
      "Info: #{File.join(tmpdir, '.env')} was not found and ENV['DEV_PORT'] is unset; falling back to localhost:3000."
    )
  end

  it 'uses xdg-open on Linux' do
    write_env("DEV_PORT=3456\n")
    command = build_command(argv: ['contact'], host_os: 'linux')

    allow(command).to receive(:command_available?).with('xdg-open').and_return(true)
    allow(command).to receive(:run_opener).with('xdg-open', 'http://localhost:3456/contact').and_return(true)

    expect(command.run).to eq(0)
  end

  it 'rejects full URLs' do
    err = StringIO.new
    command = build_command(argv: ['https://example.com'], io: { stderr: err })

    expect(command.run).to eq(1)
    expect(err.string).to include('ob only accepts local routes, not full URLs')
  end

  it 'returns a friendly error for invalid route characters' do
    write_env("DEV_PORT=4567\n")
    err = StringIO.new
    command = build_command(argv: ['contact with space'], io: { stderr: err })

    expect(command.run).to eq(1)
    expect(err.string).to include('Error: Invalid route: bad component')
  end

  it 'errors when DEV_PORT is non-numeric' do
    write_env("DEV_PORT=abc\n")
    err = StringIO.new
    command = build_command(io: { stderr: err })

    expect(command.run).to eq(1)
    expect(err.string).to include('DEV_PORT must be numeric')
  end

  it 'prints the version without opening a browser' do
    out = StringIO.new
    command = build_command(argv: ['--version'], io: { stdout: out })

    expect(command.run).to eq(0)
    expect(out.string).to eq("ob #{Rails::Worktrees::VERSION}\n")
  end

  it 'quotes quick-start examples with query strings in help output' do
    out = StringIO.new
    command = build_command(argv: ['--help'], io: { stdout: out })

    expect(command.run).to eq(0)
    expect(out.string).to include("ob '/contact?ref=nav'")
    expect(out.string).to include("ob --print-url '?from=nav'")
  end

  it 'prints the resolved URL without opening a browser' do
    write_env("DEV_PORT=4567\n")
    out = StringIO.new
    command = build_command(argv: ['--print-url', 'contact?from=nav'], io: { stdout: out })

    allow(command).to receive(:run_opener)

    expect(command.run).to eq(0)
    expect(out.string).to eq("http://localhost:4567/contact?from=nav\n")
    expect(command).not_to have_received(:run_opener)
  end

  it 'errors when DEV_PORT is outside the valid TCP port range' do
    %w[0 65536].each do |port|
      write_env("DEV_PORT=#{port}\n")
      err = StringIO.new
      command = build_command(io: { stderr: err })

      expect(command.run).to eq(1)
      expect(err.string).to include('DEV_PORT must be between 1 and 65535')
    end
  end
end
