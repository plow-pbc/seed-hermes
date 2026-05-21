#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."

mkdir -p data/workspace data/plugins

checkout_id="$(printf '%s' "$(pwd -P)" | cksum | awk '{print $1}')"
default_project="seed-hermes-${checkout_id}"
default_container="${default_project}-hermes"

if [ ! -f .env ]; then
  {
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$default_project"
    printf 'HERMES_CONTAINER_NAME=%s\n' "$default_container"
    printf 'HERMES_UID=%s\n' "$(id -u)"
    printf 'HERMES_GID=%s\n' "$(id -g)"
    printf 'HERMES_API_PORT=%s\n' "${HERMES_API_PORT:-8642}"
    printf 'HERMES_DASHBOARD_PORT=%s\n' "${HERMES_DASHBOARD_PORT:-9119}"
  } > .env
  chmod 600 .env
else
  grep -q '^COMPOSE_PROJECT_NAME=' .env || printf 'COMPOSE_PROJECT_NAME=%s\n' "$default_project" >> .env
  grep -q '^HERMES_CONTAINER_NAME=' .env || printf 'HERMES_CONTAINER_NAME=%s\n' "$default_container" >> .env
  grep -q '^HERMES_UID=' .env || printf 'HERMES_UID=%s\n' "$(id -u)" >> .env
  grep -q '^HERMES_GID=' .env || printf 'HERMES_GID=%s\n' "$(id -g)" >> .env
fi

if [ ! -f data/.env ]; then
  {
    printf '# Runtime credentials for Hermes platform gateways.\n'
    printf '# Keep this file local; it is git-ignored by the seed.\n'
  } > data/.env
  chmod 600 data/.env
fi

if [ ! -f data/config.yaml ]; then
  cat > data/config.yaml <<'YAML'
plugins:
  enabled: []
  disabled: []
terminal:
  cwd: /opt/data/workspace
model:
  provider: openai-codex
  default: gpt-5.5
YAML
fi

echo "Prepared hermes-agent/.env, data/.env, data/workspace, and data/plugins."
