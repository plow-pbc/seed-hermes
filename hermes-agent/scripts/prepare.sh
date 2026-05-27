#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."

# nousresearch/hermes-agent:latest ships with a baked-in `hermes` user at
# uid/gid 10000. Its stage2-hook (the s6-overlay cont-init script wired in
# at /etc/cont-init.d/01-hermes-setup inside the image) reads HERMES_UID
# and HERMES_GID, runs `usermod -u $HERMES_UID hermes` and
# `groupmod -o -g $HERMES_GID hermes`, then chowns the hermes-owned
# subdirs of /opt/data to that remapped uid/gid. After remap, the
# in-container hermes user *is* at the host's uid:gid.
#
# So HERMES_UID/HERMES_GID in this .env should be the host user's
# id -u / id -g — that is what makes bind-mounted writes land at
# host-owned UIDs and avoids the "host can't read what container wrote"
# pattern entirely (no group_add or setgid gymnastics needed).
#
# Migration: prepare.sh versions between PR #3 and PR #5 wrote
# HERMES_UID=10000 HERMES_GID=10000 into .env (a workaround for an older
# image that didn't have the stage2 remap path). Detect those stale
# values and rewrite them in place.
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

mkdir -p data/workspace data/plugins data/profiles

checkout_id="$(printf '%s' "$(pwd -P)" | cksum | awk '{print $1}')"
default_project="seed-hermes-${checkout_id}"
default_container="${default_project}-hermes"

write_or_replace_kv() {
  local file="$1" key="$2" value="$3"
  if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
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
write_or_replace_kv .env HERMES_UID "$HOST_UID"
write_or_replace_kv .env HERMES_GID "$HOST_GID"
write_or_replace_kv .env HERMES_API_PORT "${HERMES_API_PORT:-8642}"
write_or_replace_kv .env HERMES_DASHBOARD_PORT "${HERMES_DASHBOARD_PORT:-9119}"

# Drop the host-uid/gid keys added in PRs #3/#4 — no longer needed now
# that we let the image's stage2-hook handle UID remap + chown.
if [ -f .env ]; then
  sed -i.bak -E '/^HERMES_HOST_UID=/d; /^HERMES_HOST_GID=/d' .env
  rm -f .env.bak
fi

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

# Hermes runtime subdirs (cron, sessions, logs, etc.) are NOT pre-created
# here anymore: the image's stage2-hook does that under
# `s6-setuidgid hermes mkdir -p` after the UID remap, which is the
# canonical place. Pre-creating them host-side caused subtle ownership
# drift in PR #3 (host-owned dirs leaking under the remapped hermes user).

echo "Prepared hermes-agent/.env, data/.env, data/workspace, data/plugins, data/profiles."
echo "Host user: ${HOST_UID}:${HOST_GID} — image stage2-hook will remap the in-container hermes user to match."
