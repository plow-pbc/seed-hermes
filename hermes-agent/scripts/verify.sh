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

grep -q 'container_name: ${HERMES_CONTAINER_NAME:?Run ./scripts/prepare.sh before docker compose up}' compose.yaml || fail "container name must come from prepare.sh"
grep -q 'COMPOSE_PROJECT_NAME=' scripts/prepare.sh || fail "prepare.sh does not set a per-checkout compose project"
grep -q 'HERMES_CONTAINER_NAME=' scripts/prepare.sh || fail "prepare.sh does not set a per-checkout container name"
grep -q 'working_dir: /opt/data/workspace' compose.yaml || fail "container working_dir is not /opt/data/workspace"
grep -q './data:/opt/data' compose.yaml || fail "whole data volume is not mounted"
grep -q 'HERMES_UID:' compose.yaml || fail "HERMES_UID missing"
grep -q 'HERMES_GID:' compose.yaml || fail "HERMES_GID missing"
grep -q '\${HERMES_API_PORT:-8642}:8642' compose.yaml || fail "API port is not overridable"
grep -q '\${HERMES_DASHBOARD_PORT:-9119}:9119' compose.yaml || fail "dashboard port is not overridable"
grep -q 'cwd: /opt/data/workspace' data/config.yaml || fail "terminal.cwd is not /opt/data/workspace"
grep -q 'provider: openai-codex' data/config.yaml || fail "model.provider is not openai-codex"
if grep -q 'base_url:' data/config.yaml; then
  fail "data/config.yaml must not set model.base_url for openai-codex"
fi

if [ -d data/plugins/plow-chat-platform ]; then
  test -f data/plugins/plow-chat-platform/plugin.yaml || fail "Plow plugin plugin.yaml missing"
  test -f data/plugins/plow-chat-platform/__init__.py || fail "Plow plugin __init__.py missing"
  test -f data/plugins/plow-chat-platform/ref/hermes-plugin/plow_chat/adapter.py || fail "Plow adapter missing"
  grep -q 'plow-chat-platform' data/config.yaml || fail "Plow plugin fetched but not enabled"
fi

cd ..
git check-ignore -q hermes-agent/.env || fail "hermes-agent/.env is not git-ignored"
git check-ignore -q hermes-agent/data/.env || fail "hermes-agent/data/.env is not git-ignored"
git check-ignore -q hermes-agent/data/auth.json || fail "hermes-agent/data/auth.json is not git-ignored"
if git ls-files | grep -Eq '(^|/)auth\.json$|(^|/)data/\.env$|(^|/)hermes-agent/\.env$'; then
  fail "runtime secret files are tracked"
fi
if git grep -nE 'g[h]p_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,}|PLOW_CHAT_SECRET_KEY=.+|OPENAI_API_KEY=.+|secret_key[[:space:]]*:[[:space:]]*[^<[:space:]]' -- . ':!TESTING.md' ':!hermes-agent/scripts/verify.sh' >/tmp/seed-hermes-secret-grep.$$ 2>/dev/null; then
  cat /tmp/seed-hermes-secret-grep.$$
  rm -f /tmp/seed-hermes-secret-grep.$$
  fail "tracked files contain secret-looking literal values"
fi
rm -f /tmp/seed-hermes-secret-grep.$$

echo "seed-hermes scaffold verifies"
