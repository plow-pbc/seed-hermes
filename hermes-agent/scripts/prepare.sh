#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."

# Canonical container user baked into the upstream nousresearch/hermes-agent
# image. The Hermes runtime inside the container runs as this UID/GID. Every
# bind-mounted file under data/ that the runtime writes (sessions, cron, logs,
# hooks, memories, profiles, ...) ends up owned by these IDs. Downstream
# sidecars that read HERMES_UID/HERMES_GID from this .env (gbrain installer,
# airbnb-manager courier) must see these values — NOT the host user IDs —
# otherwise they target the wrong user inside the container and fail with
# `HOME is '/', expected '/opt/data'` or write root-owned files into data/.
#
# If the upstream image ever changes the baked-in UID/GID, override here.
HERMES_CONTAINER_UID="${HERMES_CONTAINER_UID:-10000}"
HERMES_CONTAINER_GID="${HERMES_CONTAINER_GID:-10000}"

# The host's primary group is what we pass to the container as a supplementary
# group (compose `group_add`) so the container's writes can be group-readable
# AND group-writable from the host (via setgid + umask 002).
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

mkdir -p data/workspace data/plugins data/profiles
# Pre-create the runtime subdirs that Hermes mkdirs on first start. Doing it
# here means the chown in compose.yaml's hermes-init service has something
# concrete to chown, and the main hermes service never sees a missing dir.
mkdir -p data/cron data/sessions data/logs data/hooks data/memories \
         data/skills data/skins data/plans data/home

checkout_id="$(printf '%s' "$(pwd -P)" | cksum | awk '{print $1}')"
default_project="seed-hermes-${checkout_id}"
default_container="${default_project}-hermes"

# Write or migrate .env. Migration: previous prepare.sh versions wrote
# HERMES_UID=$(id -u) HERMES_GID=$(id -g), which mismatched the image user
# (uid 10000). Detect those stale values and replace them in place.
write_or_replace_kv() {
  local file="$1" key="$2" value="$3"
  if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
    # Replace in place if value differs.
    if ! grep -qx "${key}=${value}" "$file"; then
      tmp="$(mktemp)"; grep -v "^${key}=" "$file" > "$tmp"
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
      mv "$tmp" "$file"
    fi
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

if [ ! -f .env ]; then
  : > .env
  chmod 600 .env
fi

write_or_replace_kv .env COMPOSE_PROJECT_NAME "$default_project"
write_or_replace_kv .env HERMES_CONTAINER_NAME "$default_container"
write_or_replace_kv .env HERMES_UID "$HERMES_CONTAINER_UID"
write_or_replace_kv .env HERMES_GID "$HERMES_CONTAINER_GID"
write_or_replace_kv .env HERMES_HOST_UID "$HOST_UID"
write_or_replace_kv .env HERMES_HOST_GID "$HOST_GID"
write_or_replace_kv .env HERMES_API_PORT "${HERMES_API_PORT:-8642}"
write_or_replace_kv .env HERMES_DASHBOARD_PORT "${HERMES_DASHBOARD_PORT:-9119}"

if [ ! -f data/.env ]; then
  {
    printf '# Runtime credentials for Hermes platform gateways.\n'
    printf '# Keep this file local; it is git-ignored by the seed.\n'
  } > data/.env
  chmod 644 data/.env
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

# Permission setup is deferred to the `hermes-init` compose service, which
# runs as root inside Docker (no host sudo required) and chowns data/ to
# HERMES_CONTAINER_UID:HERMES_HOST_GID with setgid bits set. See compose.yaml.
echo "Prepared hermes-agent/.env, data/.env, data/workspace, data/plugins, data/profiles, and Hermes runtime subdirs."
echo "Container user: ${HERMES_CONTAINER_UID}:${HERMES_CONTAINER_GID} (image-baked); host gid: ${HOST_GID} (for shared writes)."
