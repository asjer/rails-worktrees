module Rails
  module Worktrees
    # Shell entrypoint for the wt executable.
    class CLI
      def initialize(
        argv: ARGV,
        io: { stdin: $stdin, stdout: $stdout, stderr: $stderr },
        env: ENV,
        cwd: Dir.pwd
      )
        @argv = argv
        @io = io
        @env = env
        @cwd = cwd
      end

      def start
        Command.new(
          argv: @argv,
          io: @io,
          env: @env,
          cwd: @cwd,
          configuration: ::Rails::Worktrees.configuration
        ).run
      end
    end
  end
end
