#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."

mkdir -p data/workspace data/plugins

if [ ! -f .env ]; then
  {
    printf 'HERMES_UID=%s\n' "$(id -u)"
    printf 'HERMES_GID=%s\n' "$(id -g)"
    printf 'HERMES_API_PORT=%s\n' "${HERMES_API_PORT:-8642}"
    printf 'HERMES_DASHBOARD_PORT=%s\n' "${HERMES_DASHBOARD_PORT:-9119}"
  } > .env
  chmod 600 .env
else
  for key in HERMES_UID HERMES_GID; do
    if ! grep -q "^${key}=" .env; then
      printf '%s=%s\n' "$key" "$( [ "$key" = HERMES_UID ] && id -u || id -g )" >> .env
    fi
  done
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
