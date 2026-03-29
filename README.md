# Rails::Worktrees

`rails-worktrees` adds a Rails-friendly `bin/wt` command for creating Git worktrees with isolated development and test databases.

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add rails-worktrees
bin/rails generate rails:worktrees:install
```

The installer adds:

- `bin/wt` — a thin wrapper that executes the gem-owned CLI
- `config/initializers/rails_worktrees.rb` — optional configuration
- `Procfile.dev.worktree.example` — a copy-paste helper for `${DEV_PORT:-3000}` in `Procfile.dev`
- a safe update to `config/database.yml` for common development/test database names

## Usage

Create a new worktree from inside your Rails app:

```bash
bin/wt
bin/wt my-feature
bin/wt --dry-run my-feature
bin/wt --print-env my-feature
```

By default the command:

- creates a sibling worktrees directory next to your app, so `workspace/my-project` gets worktrees in `workspace/my-project.worktrees/<name>`
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

`WT_WORKSPACES_ROOT` and `config.workspace_root` override the destination root at runtime and use the explicit layout `<root>/<project>/<name>`.

### Configuration

The installer generates `config/initializers/rails_worktrees.rb` where you can override:

- `bootstrap_env`
- `workspace_root`
- `dev_port_range`
- `branch_prefix`
- `name_sources_path`
- `used_names_file`
- `worktree_database_suffix_max_length`

By default, the generated initializer leaves `workspace_root` commented out so the project-relative sibling layout stays active.

### Database naming

The installer attempts to add `WORKTREE_DATABASE_SUFFIX` to common `development` and `test` database names in `config/database.yml`.

For a multi-database app, the target shape is:

```yaml
development:
  primary:
    database: my_app_development<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>_primary

test:
  primary:
    database: my_app_test<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>_primary
```

If your `database.yml` is too custom to patch safely, the installer leaves it alone and tells you what to update manually.

### Worktree environment bootstrap

When `bin/wt` creates a fresh worktree, it also creates or updates a worktree-local `.env` file.

That `.env` currently manages:

- `DEV_PORT` — derived deterministically from the worktree name and `config.dev_port_range`
- `WORKTREE_DATABASE_SUFFIX` — derived from the worktree name so the generated `database.yml` ERB becomes immediately useful

Existing `.env` values win, so rerunning `bin/wt` or bootstrapping a worktree again will not overwrite a custom `DEV_PORT` or `WORKTREE_DATABASE_SUFFIX`.

If you want to preview the full worktree setup without creating anything yet, run:

```bash
bin/wt --dry-run my-feature
```

That preview resolves the worktree name, branch, target path, and `.env` values it would use, then finishes with a clear "no changes were made" summary.

If you want to preview those derived values without creating a worktree yet, run:

```bash
bin/wt --print-env my-feature
```

That command prints copy-pasteable environment lines like:

```text
DEV_PORT=3383
WORKTREE_DATABASE_SUFFIX=_my_feature
```

When `bin/wt` does create the worktree, the final summary now also echoes the chosen port and suffix so you can see the result immediately.

`rails-worktrees` does **not** edit your real `Procfile.dev` automatically. Instead, the installer generates `Procfile.dev.worktree.example` so you can copy this line into your app's process manager setup when you want Rails to honor the generated port:

```text
web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}
```

The gem also does **not** add dotenv or change Rails env loading; it only writes `.env` for your worktree. Your app or process manager still decides how that file gets loaded.

If you already use `mise`, a nice way to keep those worktree-local values up to date on directory enter is:

```toml
[env]
_.file = ".env"
```

That keeps `DEV_PORT` and `WORKTREE_DATABASE_SUFFIX` scoped to the current worktree. In general, prefer a project-local env loader like `mise` over exporting these values from `~/.zshrc`, since the values are worktree-specific and can differ across worktrees.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

### Smoke testing

RSpec remains the main automated test suite. For installer and integration changes, you can also run a disposable Rails app smoke test:

```bash
bundle exec rake smoke_test
```

This smoke test:

- creates a temporary Rails app from a compatible Rails version
- installs `rails-worktrees` from the current checkout path
- runs `bin/rails generate rails:worktrees:install`
- verifies `bin/wt`, the generated initializer, the Procfile example, `config/database.yml` patching, and worktree `.env` bootstrapping
- creates a temporary bare `origin` and confirms `bin/wt smoke-branch` creates a real worktree

By default, the script cleans up all temp directories after the run. Set `KEEP_SMOKE_TEST_ARTIFACTS=1` to keep them around for debugging, or set `RAILS_WORKTREES_SMOKE_RAILS_VERSION` to try a different compatible Rails version.

There is also a manually triggered GitHub Actions workflow named `Smoke Test` for running the same disposable-app verification in CI without slowing down the default pull request checks.

The workflow accepts optional `ruby_version`, `rails_version`, `keep_artifacts`, and `verbose` inputs. Enable `keep_artifacts` when you want the disposable app, bare origin, and worktree directories uploaded from CI for debugging, and enable `verbose` when you want shell tracing in the smoke-test log.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/asjer/rails-worktrees.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
