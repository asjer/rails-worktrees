#!/usr/bin/env bash
set -euo pipefail

unset BUNDLE_BIN_PATH BUNDLE_GEMFILE RUBYOPT

[[ "${RAILS_WORKTREES_SMOKE_VERBOSE:-0}" == "1" ]] && set -x

RAILS_VERSION="${RAILS_WORKTREES_SMOKE_RAILS_VERSION:-8.0.5}"
INFO_FILE="${RAILS_WORKTREES_SMOKE_INFO_FILE:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="$(mktemp -d /tmp/rails-worktrees-smoke.XXXXXX)"
ORIGIN_ROOT="$(mktemp -d /tmp/rails-worktrees-origin.XXXXXX)"
WORKSPACES_ROOT="$(mktemp -d /tmp/rails-worktrees-workspaces.XXXXXX)"
APP_NAME="$(basename "$APP_DIR")"
EXPECTED_WORKTREE="$WORKSPACES_ROOT/$APP_NAME/smoke-branch"

say() {
  printf '→ %s\n' "$*"
}

fail() {
  printf 'Smoke test failed: %s\n' "$*" >&2
  exit 1
}

write_info_file() {
  local status="$1"

  [[ -n "$INFO_FILE" ]] || return 0

  cat >"$INFO_FILE" <<EOF
STATUS=$status
RAILS_VERSION=$RAILS_VERSION
VERBOSE=${RAILS_WORKTREES_SMOKE_VERBOSE:-0}
APP_DIR=$APP_DIR
ORIGIN_ROOT=$ORIGIN_ROOT
WORKSPACES_ROOT=$WORKSPACES_ROOT
EXPECTED_WORKTREE=$EXPECTED_WORKTREE
EOF
}

cleanup() {
  local exit_code=$?

  write_info_file "$([[ $exit_code -eq 0 ]] && printf 'passed' || printf 'failed')"

  if [[ "${KEEP_SMOKE_TEST_ARTIFACTS:-0}" == "1" ]]; then
    printf 'Keeping smoke test artifacts:\n  app: %s\n  origin: %s\n  workspaces: %s\n' "$APP_DIR" "$ORIGIN_ROOT" "$WORKSPACES_ROOT"
    exit "$exit_code"
  fi

  if [[ $exit_code -ne 0 ]]; then
    printf 'Cleaning up failed smoke test artifacts:\n  app: %s\n  origin: %s\n  workspaces: %s\n' "$APP_DIR" "$ORIGIN_ROOT" "$WORKSPACES_ROOT" >&2
  fi

  rm -rf "$APP_DIR" "$ORIGIN_ROOT" "$WORKSPACES_ROOT"
  exit "$exit_code"
}
trap cleanup EXIT

write_info_file 'initialized'

if ! gem list '^rails$' -i -v "$RAILS_VERSION" >/dev/null 2>&1; then
  fail "Rails ${RAILS_VERSION} is not installed. Install it with: gem install rails -v ${RAILS_VERSION} --no-document"
fi

say "Creating disposable Rails app with Rails ${RAILS_VERSION}"
rails _${RAILS_VERSION}_ new "$APP_DIR" \
  --skip-javascript \
  --skip-hotwire \
  --skip-action-mailbox \
  --skip-action-text \
  --skip-active-storage \
  --skip-system-test \
  --skip-bootsnap \
  --skip-bundle

say 'Adding local rails-worktrees gem to Gemfile'
ruby - "$APP_DIR/Gemfile" "$REPO_ROOT" <<'RUBY'
path, repo_root = ARGV
content = File.read(path)
updated = content.sub(/^(gem "rails", .+\n)/) do |match|
  %(#{match}gem "rails-worktrees", path: "#{repo_root}"\n)
end
abort('Could not find Rails gem declaration in Gemfile') if updated == content
File.write(path, updated)
RUBY

cd "$APP_DIR"

say 'Installing app dependencies'
bundle install

say 'Writing sample Procfile.dev and mise.toml for installer yolo mode'
cat >Procfile.dev <<'EOF'
web:
js: yarn build --watch
EOF

cat >mise.toml <<'EOF'
[tools]
ruby = "3.4.8"
EOF

say 'Running rails-worktrees installer with --yolo'
bundle exec rails generate worktrees:install --yolo

[[ -x bin/wt ]] || fail 'Expected bin/wt to exist and be executable'
[[ -f config/initializers/rails_worktrees.rb ]] || fail 'Expected config/initializers/rails_worktrees.rb to exist'
[[ -f Procfile.dev.worktree.example ]] || fail 'Expected Procfile.dev.worktree.example to exist'
grep -Fq "development<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>" config/database.yml || fail 'Expected development database name to include WORKTREE_DATABASE_SUFFIX'
grep -Fq "test<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>" config/database.yml || fail 'Expected test database name to include WORKTREE_DATABASE_SUFFIX'
grep -Eq '^wt [0-9]+\.[0-9]+\.[0-9]+' < <(bin/wt --version) || fail 'Expected bin/wt --version to return a semantic version'
grep -Fq 'web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}' Procfile.dev.worktree.example || fail 'Expected Procfile.dev.worktree.example to include the DEV_PORT-aware web entry'
grep -Fq 'web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}' Procfile.dev || fail 'Expected Procfile.dev to include the DEV_PORT-aware web entry after --yolo'
grep -Fq 'js: yarn build --watch' Procfile.dev || fail 'Expected Procfile.dev to preserve non-web entries after --yolo'
grep -Fq '[env]' mise.toml || fail 'Expected mise.toml to include an [env] section after --yolo'
grep -Fq '_.file = ".env"' mise.toml || fail 'Expected mise.toml to load .env after --yolo'

say 'Creating temporary bare origin and pushing main'
git init --bare --initial-branch=main "$ORIGIN_ROOT/origin.git"
git add .
GIT_AUTHOR_NAME='Smoke Test' \
  GIT_AUTHOR_EMAIL='smoke@example.com' \
  GIT_COMMITTER_NAME='Smoke Test' \
  GIT_COMMITTER_EMAIL='smoke@example.com' \
  git -c commit.gpgSign=false commit -m 'Smoke test app setup'
git remote add origin "$ORIGIN_ROOT/origin.git"
git push -u origin main
git remote set-head origin -a

say 'Previewing smoke worktree environment'
PREVIEW_OUTPUT="$(WT_WORKSPACES_ROOT="$WORKSPACES_ROOT" bin/wt --print-env smoke-branch)"
printf '%s\n' "$PREVIEW_OUTPUT"

grep -Eq '^DEV_PORT=[0-9]+$' < <(printf '%s\n' "$PREVIEW_OUTPUT") || fail 'Expected wt --print-env to output DEV_PORT'
grep -Fq 'WORKTREE_DATABASE_SUFFIX=_smoke_branch' < <(printf '%s\n' "$PREVIEW_OUTPUT") || fail 'Expected wt --print-env to output WORKTREE_DATABASE_SUFFIX'

say 'Dry-running smoke worktree creation'
DRY_RUN_OUTPUT="$(WT_WORKSPACES_ROOT="$WORKSPACES_ROOT" bin/wt --dry-run smoke-branch)"
printf '%s\n' "$DRY_RUN_OUTPUT"

grep -Fq 'Dry run complete' < <(printf '%s\n' "$DRY_RUN_OUTPUT") || fail 'Expected wt --dry-run to finish successfully'
grep -Fq 'No changes were made.' < <(printf '%s\n' "$DRY_RUN_OUTPUT") || fail 'Expected wt --dry-run to report no changes'
grep -Fq "Path:   $EXPECTED_WORKTREE" < <(printf '%s\n' "$DRY_RUN_OUTPUT") || fail 'Expected wt --dry-run to show the target worktree path'
grep -Fq 'Suffix: _smoke_branch' < <(printf '%s\n' "$DRY_RUN_OUTPUT") || fail 'Expected wt --dry-run to show the database suffix'
[[ ! -d "$EXPECTED_WORKTREE" ]] || fail 'Expected wt --dry-run not to create the worktree directory'

say 'Creating smoke worktree'
CREATE_OUTPUT="$(WT_WORKSPACES_ROOT="$WORKSPACES_ROOT" bin/wt smoke-branch)"
printf '%s\n' "$CREATE_OUTPUT"

[[ -d "$EXPECTED_WORKTREE" ]] || fail "Expected worktree at $EXPECTED_WORKTREE"
[[ "$(git -C "$EXPECTED_WORKTREE" branch --show-current)" == '🚂/smoke-branch' ]] || fail 'Expected worktree branch to be 🚂/smoke-branch'
[[ -f "$EXPECTED_WORKTREE/.env" ]] || fail 'Expected worktree-local .env to exist'

grep -Eq '^DEV_PORT=[0-9]+$' "$EXPECTED_WORKTREE/.env" || fail 'Expected .env to include DEV_PORT'
grep -Fq 'WORKTREE_DATABASE_SUFFIX=_smoke_branch' "$EXPECTED_WORKTREE/.env" || fail 'Expected .env to include WORKTREE_DATABASE_SUFFIX'

ACTUAL_DEV_PORT="$(grep '^DEV_PORT=' "$EXPECTED_WORKTREE/.env" | cut -d= -f2)"
grep -Fq "DEV_PORT=$ACTUAL_DEV_PORT" < <(printf '%s\n' "$PREVIEW_OUTPUT") || fail 'Expected wt --print-env DEV_PORT to match the created .env'
grep -Fq "Port:   $ACTUAL_DEV_PORT" < <(printf '%s\n' "$CREATE_OUTPUT") || fail 'Expected worktree summary to include the chosen DEV_PORT'

grep -Fq "$EXPECTED_WORKTREE" < <(git worktree list) || fail 'Expected git worktree list to include the created worktree'

printf '✅ Smoke test passed\n'
printf 'App template: %s\nWorktree: %s\n' "$APP_DIR" "$EXPECTED_WORKTREE"
