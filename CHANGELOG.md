# Changelog

## [0.2.0](https://github.com/asjer/rails-worktrees/compare/v0.1.1...v0.2.0) (2026-03-30)


### Features

* add `--yolo` mode to install common follow-ups without manual edits ([1ec82ec](https://github.com/asjer/rails-worktrees/commit/1ec82ec83726b5ca9cbaee39697c607fdb825f26))

## [0.1.1](https://github.com/asjer/rails-worktrees/compare/v0.1.0...v0.1.1) (2026-03-30)


### Bug Fixes

* **bin/wt:** remove unnecessary frozen_string_literal comment ([e3752c8](https://github.com/asjer/rails-worktrees/commit/e3752c86e4003b80e401253e3c07bd0107ba1514))
* **ci:** update gem installation steps to prevent `Gemfile.lock` freeze ([e3c75e8](https://github.com/asjer/rails-worktrees/commit/e3c75e85528e575185adb417b6bd9efa995087f1))
* **frozen-string-literal:** remove unnecessary frozen_string_literal comments ([a8583d2](https://github.com/asjer/rails-worktrees/commit/a8583d2bab1097a6c6a1906a3d6f6092d7b8d867))
* **generator:** update generator command to use shorter namespace ([cef728e](https://github.com/asjer/rails-worktrees/commit/cef728e3642c36da054f0d53ab5d8a932b2511c4))
* **installation:** show setup instructions on boot when generator hasn't run ([af31a3f](https://github.com/asjer/rails-worktrees/commit/af31a3f3849408cf7098e2a4e90a9246c89b0bbe))

## 0.1.0 (2026-03-30)


### Features

* add wt command and rails installer ([5d798d5](https://github.com/asjer/rails-worktrees/commit/5d798d5129585331780f0259b39061194feb66e3))

## [Unreleased]

- Add a gem-managed `wt` CLI for creating Rails worktrees.
- Add a Rails installer generator that creates `bin/wt` and `config/initializers/rails_worktrees.rb`.
- Add conservative `config/database.yml` patching for common development/test database names.
- Add a manual-dispatch GitHub Actions workflow for the disposable Rails smoke test.
- Add smoke-test workflow debug controls for retained artifacts and verbose output.
