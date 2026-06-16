#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test -f compose.yaml || fail "compose.yaml missing"
test -f data/config.yaml || fail "data/config.yaml missing"
test -d data/workspace || fail "data/workspace missing"
test -d data/plugins || fail "data/plugins missing"
test -d data/profiles || fail "data/profiles missing"

grep -q 'container_name: ${HERMES_CONTAINER_NAME:?Run ./scripts/prepare.sh before docker compose up}' compose.yaml || fail "container name must come from prepare.sh"
grep -q '^    image: nousresearch/hermes-agent:latest' compose.yaml || fail "compose must use upstream image directly (no derived Dockerfile)"
if grep -q '^    build:' compose.yaml; then
  fail "compose must NOT build a derived image — upstream image already does init+UID+codex-fix natively"
fi
if grep -q '^    entrypoint:' compose.yaml; then
  fail "compose must NOT set entrypoint — image's /init + main-wrapper.sh is the canonical entrypoint"
fi
if grep -q '^    user:' compose.yaml; then
  fail "compose must NOT set user — image stage2-hook reads HERMES_UID and remaps the in-container hermes user itself"
fi
if grep -q '^    group_add:' compose.yaml; then
  fail "compose must NOT group_add — image stage2-hook chowns to the remapped hermes uid/gid directly"
fi

if [ -e Dockerfile ]; then
  fail "Dockerfile must NOT exist — upstream image now does init+UID+codex-fix natively (PRs #3/#4/#5 architecture superseded)"
fi
if [ -e entrypoint ]; then
  fail "entrypoint/ directory must NOT exist — seed-entrypoint.sh's responsibilities moved into the upstream image's stage2-hook + main-wrapper.sh"
fi

test -x cont-init.d/50-install-jq.sh || fail "cont-init.d/50-install-jq.sh missing or not executable"
grep -q '\./cont-init\.d/50-install-jq\.sh:/etc/cont-init\.d/50-install-jq\.sh:ro' compose.yaml \
  || fail "compose must bind-mount the jq cont-init hook into /etc/cont-init.d/"

grep -q 'COMPOSE_PROJECT_NAME' scripts/prepare.sh || fail "prepare.sh does not set a per-checkout compose project"
grep -q 'HERMES_CONTAINER_NAME' scripts/prepare.sh || fail "prepare.sh does not set a per-checkout container name"
grep -q 'HOST_UID="\$(id -u)"' scripts/prepare.sh || fail "prepare.sh must source HERMES_UID from \$(id -u) — image stage2-hook remaps the in-container hermes user to it"
grep -q 'HOST_GID="\$(id -g)"' scripts/prepare.sh || fail "prepare.sh must source HERMES_GID from \$(id -g)"

grep -q 'working_dir: /opt/data/workspace' compose.yaml || fail "container working_dir is not /opt/data/workspace"
grep -q './data:/opt/data' compose.yaml || fail "whole data volume is not mounted"
grep -q 'HERMES_UID:' compose.yaml || fail "HERMES_UID env var missing from compose"
grep -q 'HERMES_GID:' compose.yaml || fail "HERMES_GID env var missing from compose"
grep -q '\${HERMES_API_PORT:-8642}:8642' compose.yaml || fail "API port is not overridable"
grep -q '\${HERMES_DASHBOARD_PORT:-9119}:9119' compose.yaml || fail "dashboard port is not overridable"
grep -q 'HERMES_DASHBOARD: "1"' compose.yaml || fail "dashboard is not enabled by default"
grep -q 'cwd: /opt/data/workspace' data/config.yaml || fail "terminal.cwd is not /opt/data/workspace"
grep -q 'provider: openai-codex' data/config.yaml || fail "model.provider is not openai-codex"
if awk '
  /^[^[:space:]#]/ { in_model = ($0 ~ /^model:/) }
  in_model && /^[[:space:]]+base_url:/ { found = 1 }
  END { exit(found ? 0 : 1) }
' data/config.yaml; then
  fail "data/config.yaml must not set model.base_url for openai-codex"
fi

# .env contract: HERMES_UID/GID must be host id (image stage2-hook remaps).
test -f .env || fail ".env missing — run ./scripts/prepare.sh"
host_uid="$(id -u)"; host_gid="$(id -g)"
grep -qx "HERMES_UID=${host_uid}" .env || fail ".env HERMES_UID must be host \$(id -u)=${host_uid}; image stage2-hook remaps the in-container hermes user to it"
grep -qx "HERMES_GID=${host_gid}" .env || fail ".env HERMES_GID must be host \$(id -g)=${host_gid}"
if grep -qE '^HERMES_HOST_(UID|GID)=' .env; then
  fail ".env must NOT contain HERMES_HOST_UID/HERMES_HOST_GID — those keys were retired with seed-entrypoint.sh"
fi

test -x scripts/hermes-exec.sh || fail "scripts/hermes-exec.sh missing or not executable"
grep -q 'docker compose exec -u' scripts/hermes-exec.sh || fail "hermes-exec.sh must pass -u <uid>:<gid> to docker compose exec"

test -x scripts/yaml-get.sh || fail "scripts/yaml-get.sh missing or not executable"
grep -q 'docker compose exec -T hermes' scripts/yaml-get.sh || fail "yaml-get.sh must shell into the hermes container"

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
