# Changelog

## 0.1.0 (2026-03-30)


### Features

* add wt command and rails installer ([5d798d5](https://github.com/asjer/rails-worktrees/commit/5d798d5129585331780f0259b39061194feb66e3))

## [Unreleased]

- Add a gem-managed `wt` CLI for creating Rails worktrees.
- Add a Rails installer generator that creates `bin/wt` and `config/initializers/rails_worktrees.rb`.
- Add conservative `config/database.yml` patching for common development/test database names.
- Add a manual-dispatch GitHub Actions workflow for the disposable Rails smoke test.
- Add smoke-test workflow debug controls for retained artifacts and verbose output.
