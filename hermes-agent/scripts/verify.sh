#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test -f compose.yaml || fail "compose.yaml missing"
test -f Dockerfile || fail "Dockerfile missing (needed for build-time hermes symlink + jq)"
test -f data/config.yaml || fail "data/config.yaml missing"
test -d data/workspace || fail "data/workspace missing"
test -d data/plugins || fail "data/plugins missing"
test -d data/profiles || fail "data/profiles missing"
# Runtime subdirs pre-created by prepare.sh so the container doesn't have to
# mkdir at startup on a bind-mounted parent it doesn't own yet.
for sub in cron sessions logs hooks memories skills skins plans home; do
  test -d "data/$sub" || fail "data/$sub missing (prepare.sh must pre-create runtime subdirs)"
done

grep -q 'container_name: ${HERMES_CONTAINER_NAME:?Run ./scripts/prepare.sh before docker compose up}' compose.yaml || fail "container name must come from prepare.sh"
grep -q 'ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes' Dockerfile || fail "Dockerfile does not bake the /usr/local/bin/hermes symlink"
grep -qE 'apt-get install.*jq' Dockerfile || fail "Dockerfile does not bake jq (defect #21)"
if grep -q 'ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes' compose.yaml; then
  fail "compose.yaml still creates the hermes symlink at runtime (must move to Dockerfile)"
fi
grep -q 'build:' compose.yaml || fail "compose.yaml must build from the local Dockerfile"

# Permission model contract
grep -q '^  hermes-init:' compose.yaml || fail "compose.yaml must define a hermes-init service that chowns data/"
grep -q 'service_completed_successfully' compose.yaml || fail "hermes service must depends_on hermes-init with service_completed_successfully"
grep -q 'group_add:' compose.yaml || fail "hermes service must group_add the host gid so writes are host-readable+writable"
grep -q 'umask 002' compose.yaml || fail "hermes command must set umask 002 so new files are group-writable"

# .env contract: HERMES_UID/GID match the image (10000), and HERMES_HOST_GID
# is recorded for the init service + group_add.
test -f .env || fail ".env missing — run ./scripts/prepare.sh"
grep -qx 'HERMES_UID=10000' .env || fail ".env HERMES_UID must be 10000 (image-baked container user), not the host uid"
grep -qx 'HERMES_GID=10000' .env || fail ".env HERMES_GID must be 10000 (image-baked container user), not the host gid"
grep -q '^HERMES_HOST_GID=' .env || fail ".env must define HERMES_HOST_GID (used by hermes-init chown + main service group_add)"
grep -q '^HERMES_HOST_UID=' .env || fail ".env must define HERMES_HOST_UID"

test -x scripts/hermes-exec.sh || fail "scripts/hermes-exec.sh missing or not executable"
grep -q 'docker compose exec -u' scripts/hermes-exec.sh || fail "hermes-exec.sh must pass -u <uid>:<gid> to docker compose exec"

test -x scripts/yaml-get.sh || fail "scripts/yaml-get.sh missing or not executable (defect #31 — replaces host PyYAML dep)"
grep -q 'docker compose exec -T hermes' scripts/yaml-get.sh || fail "yaml-get.sh must shell into the hermes container"

grep -q 'COMPOSE_PROJECT_NAME' scripts/prepare.sh || fail "prepare.sh does not set a per-checkout compose project"
grep -q 'HERMES_CONTAINER_NAME' scripts/prepare.sh || fail "prepare.sh does not set a per-checkout container name"
grep -q 'working_dir: /opt/data/workspace' compose.yaml || fail "container working_dir is not /opt/data/workspace"
grep -q './data:/opt/data' compose.yaml || fail "whole data volume is not mounted"
grep -q 'HERMES_UID:' compose.yaml || fail "HERMES_UID missing"
grep -q 'HERMES_GID:' compose.yaml || fail "HERMES_GID missing"
grep -q '\${HERMES_API_PORT:-8642}:8642' compose.yaml || fail "API port is not overridable"
grep -q '\${HERMES_DASHBOARD_PORT:-9119}:9119' compose.yaml || fail "dashboard port is not overridable"
grep -q 'HERMES_DASHBOARD: "1"' compose.yaml || fail "dashboard is not enabled by default"
grep -q 'cwd: /opt/data/workspace' data/config.yaml || fail "terminal.cwd is not /opt/data/workspace"
grep -q 'provider: openai-codex' data/config.yaml || fail "model.provider is not openai-codex"
if grep -q 'base_url:' data/config.yaml; then
  fail "data/config.yaml must not set model.base_url for openai-codex"
fi

cd ..
git check-ignore -q hermes-agent/.env || fail "hermes-agent/.env is not git-ignored"
git check-ignore -q hermes-agent/data/.env || fail "hermes-agent/data/.env is not git-ignored"
git check-ignore -q hermes-agent/data/auth.json || fail "hermes-agent/data/auth.json is not git-ignored"
if git ls-files | grep -Eq '(^|/)auth\.json$|(^|/)data/\.env$|(^|/)hermes-agent/\.env$'; then
  fail "runtime secret files are tracked"
fi
if git grep -nE 'g[h]p_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,}|OPENAI_API_KEY=.+|secret_key[[:space:]]*:[[:space:]]*[^<[:space:]]' -- . ':!TESTING.md' ':!hermes-agent/scripts/verify.sh' >/tmp/seed-hermes-secret-grep.$$ 2>/dev/null; then
  cat /tmp/seed-hermes-secret-grep.$$
  rm -f /tmp/seed-hermes-secret-grep.$$
  fail "tracked files contain secret-looking literal values"
fi
rm -f /tmp/seed-hermes-secret-grep.$$

echo "seed-hermes scaffold verifies"
