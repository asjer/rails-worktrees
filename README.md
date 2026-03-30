# Rails::Worktrees

`rails-worktrees` adds a Rails-friendly `bin/wt` command for creating Git worktrees with isolated development and test databases.

## Requirements

- Ruby >= 3.2.0
- Rails >= 7.1, < 8.2
- Git

## Installation

```bash
bundle add rails-worktrees
bin/rails generate worktrees:install
# or, to apply the common Procfile.dev + mise follow-ups automatically:
bin/rails generate worktrees:install --yolo
```

The installer adds:

- `bin/wt` — a thin wrapper that executes the gem-owned CLI
- `config/initializers/rails_worktrees.rb` — optional configuration
- `Procfile.dev.worktree.example` — a copy-paste helper for `${DEV_PORT:-3000}` in `Procfile.dev`
- a safe update to `config/database.yml` for common development/test database names

With `--yolo`, the installer also:

- replaces the existing `web:` entry in `Procfile.dev` with the DEV_PORT-aware command when `Procfile.dev` already exists
- updates `mise.toml` or `.mise.toml` to load `.env` from `[env]` when either file already exists

## Usage

```bash
bin/wt                          # auto-pick a name from bundled *.txt lists
bin/wt my-feature               # use an explicit worktree name
bin/wt --dry-run my-feature     # preview the full setup without changing anything
bin/wt --print-env my-feature   # preview DEV_PORT and WORKTREE_DATABASE_SUFFIX
```

### Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show the help message |
| `-v`, `--version` | Show the script version |
| `--dry-run [name]` | Preview the full worktree setup without changing anything |
| `--env`, `--print-env <name>` | Preview `DEV_PORT` and `WORKTREE_DATABASE_SUFFIX` |

### Default behavior

By default `bin/wt`:

- creates a sibling directory next to your app: `workspace/my-project.worktrees/<name>`
- uses a branch named `🚂/<name>`
- creates new branches from `origin`'s default branch
- auto-picks names from bundled `.txt` files when no explicit name is given
- retires bundled names so they are not picked twice
- bootstraps a worktree-local `.env` with deterministic `DEV_PORT` and `WORKTREE_DATABASE_SUFFIX` values

```text
workspace/
├── my-project/
└── my-project.worktrees/
    ├── feature-auth/
    ├── bugfix-123/
    └── experiment/
```

`WT_WORKSPACES_ROOT` or `config.workspace_root` overrides the destination root and uses the layout `<root>/<project>/<name>`.

### Interactive prompts

`bin/wt` handles several edge cases interactively:

- **Branch already exists locally** — asks whether to attach a new worktree to it
- **Branch already exists on origin** — asks whether to create a local tracking worktree
- **Target directory already exists with matching branch** — asks whether to reuse it
- **Target directory already exists with a different branch** — asks whether to remove and recreate it
- **Retired bundled name used explicitly** — rejects it and suggests running `wt` with no argument

### Name validation

Worktree names must not contain `/` or whitespace, must not be `.` or `..`, and must be a valid Git ref component.

### Configuration

The installer generates `config/initializers/rails_worktrees.rb` where you can override:

| Option | Default | Description |
|--------|---------|-------------|
| `bootstrap_env` | `true` | Write `.env` when creating a worktree |
| `workspace_root` | `nil` | Override the destination root (sibling layout when `nil`) |
| `dev_port_range` | `3000..3999` | Port range for deterministic `DEV_PORT` allocation |
| `branch_prefix` | `🚂` | Prefix for worktree branch names |
| `name_sources_path` | bundled `names/` | Directory containing `.txt` name lists |
| `used_names_file` | `~/.local/state/rails-worktrees/used-names.tsv` | TSV tracking retired names |
| `worktree_database_suffix_max_length` | `18` | Max length for generated database suffixes |

### Database naming

The installer adds `WORKTREE_DATABASE_SUFFIX` to common `development` and `test` database names in `config/database.yml`. For a multi-database app, the target shape is:

```yaml
development:
  primary:
    database: my_app_development<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>_primary

test:
  primary:
    database: my_app_test<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>_primary
```

If your `database.yml` is too custom to patch safely, the installer leaves it alone and tells you what to update manually.

### Environment bootstrap

When `bin/wt` creates a worktree it writes a worktree-local `.env` with:

- `DEV_PORT` — deterministic port derived from the worktree name via CRC32, rotated through `dev_port_range`, skipping ports already claimed by peer worktrees
- `WORKTREE_DATABASE_SUFFIX` — derived from the worktree name so the `database.yml` ERB works immediately

Existing `.env` values are never overwritten.

By default, the installer does **not** edit your `Procfile.dev` or `mise` config. It generates `Procfile.dev.worktree.example` with a ready-to-copy line:

```text
web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}
```

If you run `bin/rails generate worktrees:install --yolo`, the installer applies the two common follow-ups for you when the files already exist:

- replace the existing `web:` entry in `Procfile.dev`
- add `_.file = ".env"` to the `[env]` section of `mise.toml` or `.mise.toml`

Use a project-local env loader like `mise` with `_.file = ".env"` to keep values scoped per-worktree.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Smoke testing

RSpec remains the main automated test suite. For installer and integration changes, you can also run a disposable Rails app smoke test:

```bash
bundle exec rake smoke_test
```

This smoke test:

- creates a temporary Rails app from a compatible Rails version
- installs `rails-worktrees` from the current checkout path
- runs `bin/rails generate worktrees:install --yolo`
- verifies `bin/wt`, the generated initializer, the Procfile example, yolo updates to `Procfile.dev` and `mise.toml`, `config/database.yml` patching, and worktree `.env` bootstrapping
- creates a temporary bare `origin` and confirms `bin/wt smoke-branch` creates a real worktree

By default, the script cleans up all temp directories after the run. Set `KEEP_SMOKE_TEST_ARTIFACTS=1` to keep them around for debugging, or set `RAILS_WORKTREES_SMOKE_RAILS_VERSION` to try a different compatible Rails version.

There is also a manually triggered GitHub Actions workflow named `Smoke Test` for running the same disposable-app verification in CI without slowing down the default pull request checks.

The workflow accepts optional `ruby_version`, `rails_version`, `keep_artifacts`, and `verbose` inputs. Enable `keep_artifacts` when you want the disposable app, bare origin, and worktree directories uploaded from CI for debugging, and enable `verbose` when you want shell tracing in the smoke-test log.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/asjer/rails-worktrees.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
