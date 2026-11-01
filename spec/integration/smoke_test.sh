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
RUNNER_WORKTREE="$WORKSPACES_ROOT/$APP_NAME/runner"

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

say 'Adding local rails-worktrees gem to the development group in Gemfile'
ruby - "$APP_DIR/Gemfile" "$REPO_ROOT" <<'RUBY'
path, repo_root = ARGV
content = File.read(path)
updated = content.sub(/^(gem "rails", .+\n)/) do |match|
  %(#{match}gem "rails-worktrees", path: "#{repo_root}", group: :development\n)
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
[[ -x bin/ob ]] || fail 'Expected bin/ob to exist and be executable'
[[ -f config/initializers/rails_worktrees.rb ]] || fail 'Expected config/initializers/rails_worktrees.rb to exist'
[[ ! -f Procfile.dev.worktree.example ]] || fail 'Expected --yolo install not to create Procfile.dev.worktree.example'
grep -Fq "development<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>" config/database.yml || fail 'Expected development database name to include WORKTREE_DATABASE_SUFFIX'
grep -Fq "test<%= ENV.fetch('WORKTREE_DATABASE_SUFFIX', '') %>" config/database.yml || fail 'Expected test database name to include WORKTREE_DATABASE_SUFFIX'
grep -Eq '^wt [0-9]+\.[0-9]+\.[0-9]+' < <(bin/wt --version) || fail 'Expected bin/wt --version to return a semantic version'
grep -Eq '^ob [0-9]+\.[0-9]+\.[0-9]+' < <(bin/ob --version) || fail 'Expected bin/ob --version to return a semantic version'
grep -Fq 'web: env RUBY_DEBUG_OPEN=true bin/rails server -b 0.0.0.0 -p ${DEV_PORT:-3000}' Procfile.dev || fail 'Expected Procfile.dev to include the DEV_PORT-aware web entry after --yolo'
grep -Fq 'js: yarn build --watch' Procfile.dev || fail 'Expected Procfile.dev to preserve non-web entries after --yolo'
grep -Fq "port ENV['DEV_PORT'] || ENV.fetch('PORT', 3000)" config/puma.rb || fail 'Expected config/puma.rb to prefer DEV_PORT after --yolo'
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

say 'Regressing the generated initializer to simulate an outdated install'
cat >config/initializers/rails_worktrees.rb <<'EOF'
Rails::Worktrees.configure do |config|
  # config.bootstrap_env = false
end
EOF

say 'Auditing stale installer files with wt doctor'
set +e
DOCTOR_OUTPUT="$(bin/wt doctor 2>&1)"
DOCTOR_EXIT=$?
set -e
printf '%s\n' "$DOCTOR_OUTPUT"

[[ $DOCTOR_EXIT -eq 1 ]] || fail 'Expected wt doctor to report the stale initializer as a fixable issue'
grep -Fq 'config/initializers/rails_worktrees.rb can be updated automatically.' < <(printf '%s\n' "$DOCTOR_OUTPUT") || fail 'Expected wt doctor to flag the initializer guard drift'

say 'Previewing safe maintenance fixes with wt update --dry-run'
UPDATE_DRY_RUN_OUTPUT="$(bin/wt update --dry-run)"
printf '%s\n' "$UPDATE_DRY_RUN_OUTPUT"

grep -Fq 'Would update config/initializers/rails_worktrees.rb' < <(printf '%s\n' "$UPDATE_DRY_RUN_OUTPUT") || fail 'Expected wt update --dry-run to preview the initializer fix'
grep -Fq 'No changes were made.' < <(printf '%s\n' "$UPDATE_DRY_RUN_OUTPUT") || fail 'Expected wt update --dry-run to leave files untouched'

say 'Applying safe maintenance fixes with wt update'
UPDATE_OUTPUT="$(bin/wt update)"
printf '%s\n' "$UPDATE_OUTPUT"

grep -Fq 'Update complete' < <(printf '%s\n' "$UPDATE_OUTPUT") || fail 'Expected wt update to finish successfully'
grep -Fq 'Rails.application.config.x.rails_worktrees.tap do |config|' config/initializers/rails_worktrees.rb || fail 'Expected wt update to restore the current managed initializer format'

say 'Confirming wt doctor reports a healthy checkout after wt update'
HEALTHY_DOCTOR_OUTPUT="$(bin/wt doctor 2>&1)"
printf '%s\n' "$HEALTHY_DOCTOR_OUTPUT"

grep -Fq 'Doctor found no issues.' < <(printf '%s\n' "$HEALTHY_DOCTOR_OUTPUT") || fail 'Expected wt doctor to report a healthy checkout after wt update'

say 'Booting Rails test environment after wt update repaired the initializer'
TEST_BOOT_OUTPUT="$(bundle exec rails runner -e test 'puts %q(TEST_BOOT_OK)')"
printf '%s\n' "$TEST_BOOT_OUTPUT"

grep -Fq 'TEST_BOOT_OK' < <(printf '%s\n' "$TEST_BOOT_OUTPUT") || fail 'Expected Rails test environment to boot successfully after wt update repaired the initializer'

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

say 'Printing a smoke worktree browser URL'
PRINT_URL_OUTPUT="$(cd "$EXPECTED_WORKTREE" && bin/ob --print-url 'contact?from=nav')"
printf '%s\n' "$PRINT_URL_OUTPUT"

grep -Fq "http://localhost:$ACTUAL_DEV_PORT/contact?from=nav" < <(printf '%s\n' "$PRINT_URL_OUTPUT") || fail 'Expected bin/ob --print-url to resolve the worktree-local localhost URL'

say 'Rerunning setup inside the existing smoke worktree'
SETUP_OUTPUT="$(cd "$EXPECTED_WORKTREE" && bin/wt setup)"
printf '%s\n' "$SETUP_OUTPUT"

grep -Fq 'Setup complete' < <(printf '%s\n' "$SETUP_OUTPUT") || fail 'Expected wt setup to finish successfully inside the existing worktree'
grep -Fq "Port:   $ACTUAL_DEV_PORT" < <(printf '%s\n' "$SETUP_OUTPUT") || fail 'Expected wt setup to preserve the existing DEV_PORT'
grep -Fq 'Suffix: _smoke_branch' < <(printf '%s\n' "$SETUP_OUTPUT") || fail 'Expected wt setup to preserve the existing database suffix'

grep -Fq "$EXPECTED_WORKTREE" < <(git worktree list) || fail 'Expected git worktree list to include the created worktree'

say 'Creating a sibling runner worktree'
RUNNER_OUTPUT="$(WT_WORKSPACES_ROOT="$WORKSPACES_ROOT" bin/wt runner)"
printf '%s\n' "$RUNNER_OUTPUT"

[[ -d "$RUNNER_WORKTREE" ]] || fail "Expected runner worktree at $RUNNER_WORKTREE"
[[ "$(git -C "$RUNNER_WORKTREE" branch --show-current)" == '🚂/runner' ]] || fail 'Expected runner worktree branch to be 🚂/runner'

say 'Checking teardown with real Rails environment URLs and production metadata'
cp "$EXPECTED_WORKTREE/config/database.yml" "$EXPECTED_WORKTREE/config/database.yml.smoke-backup"
cp "$EXPECTED_WORKTREE/config/environments/test.rb" "$EXPECTED_WORKTREE/config/environments/test.rb.smoke-backup"
cp "$EXPECTED_WORKTREE/config/environments/development.rb" "$EXPECTED_WORKTREE/config/environments/development.rb.smoke-backup"
cat >"$EXPECTED_WORKTREE/config/database.yml" <<'EOF'
development:
  url: sqlite3:<%= Rails.root.join('storage/development_smoke_branch.sqlite3') %>
test:
  adapter: sqlite3
  database: storage/<%= Rails.env.test? ? 'test_boot_smoke_branch' : 'fallback_test_smoke_branch' %>.sqlite3
EOF
printf '\nENV["DATABASE_URL"] = "sqlite3:%s/storage/effective_test_smoke_branch.sqlite3"\n' "$EXPECTED_WORKTREE" >>"$EXPECTED_WORKTREE/config/environments/test.rb"
TEARDOWN_PREVIEW="$(cd "$EXPECTED_WORKTREE" && bin/wt teardown --dry-run)"
printf '%s\n' "$TEARDOWN_PREVIEW"
grep -Fq 'effective_test_smoke_branch.sqlite3' <<<"$TEARDOWN_PREVIEW" || fail 'Expected actual test environment DATABASE_URL, not the development-loaded fallback'
if grep -Fq 'fallback_test_smoke_branch.sqlite3' <<<"$TEARDOWN_PREVIEW"; then
  fail 'Teardown must not select the fallback test database'
fi
[[ ! -e "$EXPECTED_WORKTREE/storage/effective_test_smoke_branch.sqlite3" ]] || fail 'Dry-run must not create an absent SQLite database'

(cd "$EXPECTED_WORKTREE" && bin/rails runner -e test 'pool = ActiveRecord::Base.connection_pool; pool.schema_migration.create_table; pool.schema_migration.create_version("1"); pool.internal_metadata.create_table_and_set_flags("production")')
if PROTECTED_OUTPUT="$(cd "$EXPECTED_WORKTREE" && DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/wt teardown 2>&1)"; then
  fail 'Teardown must refuse production metadata even when the environment check override is set'
fi
grep -Fq 'production' <<<"$PROTECTED_OUTPUT" || fail 'Expected Rails protected environment refusal'
[[ -e "$EXPECTED_WORKTREE/storage/development_smoke_branch.sqlite3" ]] || fail 'Protected test database must prevent development deletion too'
[[ -e "$EXPECTED_WORKTREE/storage/effective_test_smoke_branch.sqlite3" ]] || fail 'Protected test database must be retained'
(cd "$EXPECTED_WORKTREE" && bin/rails runner -e test 'ActiveRecord::Base.connection_pool.internal_metadata[:environment] = "test"')

say 'Checking explicit YAML URL protection cannot be redirected by a conflicting environment URL'
printf '\nENV["DATABASE_URL"] = "sqlite3:%s/storage/decoy_development_smoke_branch.sqlite3"\n' "$EXPECTED_WORKTREE" >>"$EXPECTED_WORKTREE/config/environments/development.rb"
(cd "$EXPECTED_WORKTREE" && bin/rails runner -e development 'pool = ActiveRecord::Base.connection_pool; pool.schema_migration.create_table; pool.schema_migration.create_version("1"); pool.internal_metadata.create_table_and_set_flags("production")')
touch "$EXPECTED_WORKTREE/.overmind.sock"
if EXPLICIT_URL_OUTPUT="$(cd "$EXPECTED_WORKTREE" && bin/wt teardown 2>&1)"; then
  fail 'Explicit YAML URL with production metadata must be protected'
fi
grep -Fq 'production' <<<"$EXPLICIT_URL_OUTPUT" || fail 'Expected protection of the explicit YAML URL, not an environment URL decoy'
if grep -Fq 'Stopping Overmind' <<<"$EXPLICIT_URL_OUTPUT"; then
  fail 'Production metadata must be checked before stopping Overmind'
fi
[[ -e "$EXPECTED_WORKTREE/storage/development_smoke_branch.sqlite3" ]] || fail 'Explicit protected database must remain'
[[ -e "$EXPECTED_WORKTREE/storage/effective_test_smoke_branch.sqlite3" ]] || fail 'Protected development must retain test too'
mv "$EXPECTED_WORKTREE/.overmind.sock" "$ORIGIN_ROOT/checked-overmind.sock"
(cd "$EXPECTED_WORKTREE" && bin/rails runner -e development 'ActiveRecord::Base.connection_pool.internal_metadata[:environment] = "development"')
TEARDOWN_OUTPUT="$(cd "$EXPECTED_WORKTREE" && bin/wt teardown)"
printf '%s\n' "$TEARDOWN_OUTPUT"
[[ ! -e "$EXPECTED_WORKTREE/storage/effective_test_smoke_branch.sqlite3" ]] || fail 'Expected the effective test database to be dropped'
[[ -d "$EXPECTED_WORKTREE" ]] || fail 'Standalone teardown must keep the checkout'
[[ "$(git -C "$EXPECTED_WORKTREE" branch --show-current)" == '🚂/smoke-branch' ]] || fail 'Standalone teardown must keep the branch'
mv "$EXPECTED_WORKTREE/config/database.yml.smoke-backup" "$EXPECTED_WORKTREE/config/database.yml"
mv "$EXPECTED_WORKTREE/config/environments/test.rb.smoke-backup" "$EXPECTED_WORKTREE/config/environments/test.rb"
mv "$EXPECTED_WORKTREE/config/environments/development.rb.smoke-backup" "$EXPECTED_WORKTREE/config/environments/development.rb"

say 'Checking removal isolates sibling DATABASE_URL and named database URLs'
ISOLATED_PREVIEW="$(cd "$RUNNER_WORKTREE" && DATABASE_URL="sqlite3:$RUNNER_WORKTREE/storage/sibling_smoke_branch.sqlite3" PRIMARY_DATABASE_URL="sqlite3:$RUNNER_WORKTREE/storage/sibling_smoke_branch.sqlite3" WT_WORKSPACES_ROOT="$WORKSPACES_ROOT" bin/wt remove --dry-run smoke-branch)"
grep -Fq 'development_smoke_branch.sqlite3' <<<"$ISOLATED_PREVIEW" || fail 'Expected target development database'
if grep -Fq 'sibling_smoke_branch.sqlite3' <<<"$ISOLATED_PREVIEW"; then
  fail 'Removal must never borrow sibling database URLs'
fi

say 'Committing and merging the smoke worktree branch'
printf 'smoke removal\n' >"$EXPECTED_WORKTREE/tmp_remove.txt"
git -C "$EXPECTED_WORKTREE" add tmp_remove.txt
GIT_AUTHOR_NAME='Smoke Test' \
  GIT_AUTHOR_EMAIL='smoke@example.com' \
  GIT_COMMITTER_NAME='Smoke Test' \
  GIT_COMMITTER_EMAIL='smoke@example.com' \
  git -C "$EXPECTED_WORKTREE" -c commit.gpgSign=false commit -m 'Smoke branch change'
git merge --no-ff '🚂/smoke-branch' -m 'Merge smoke branch'
git push origin main

say 'Removing the merged smoke worktree from the sibling runner worktree'
REMOVE_OUTPUT="$(cd "$RUNNER_WORKTREE" && WT_WORKSPACES_ROOT="$WORKSPACES_ROOT" bin/wt remove smoke-branch)"
printf '%s\n' "$REMOVE_OUTPUT"

[[ ! -d "$EXPECTED_WORKTREE" ]] || fail 'Expected wt remove to delete the smoke worktree directory'
if git show-ref --verify --quiet 'refs/heads/🚂/smoke-branch'; then
  fail 'Expected wt remove to delete the local smoke branch'
fi
grep -Fq "$RUNNER_WORKTREE" < <(git worktree list) || fail 'Expected git worktree list to keep the runner worktree'
if grep -Fq "$EXPECTED_WORKTREE" < <(git worktree list); then
  fail 'Expected git worktree list to stop listing the removed smoke worktree'
fi

printf '✅ Smoke test passed\n'
printf 'App template: %s\nWorktree: %s\n' "$APP_DIR" "$RUNNER_WORKTREE"
