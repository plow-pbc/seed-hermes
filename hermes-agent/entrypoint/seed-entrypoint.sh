#!/usr/bin/env bash
#
# seed-entrypoint.sh — canonical entrypoint for seed-hermes containers.
#
# Replaces the upstream nousresearch/hermes-agent entrypoint with a wrapper
# that addresses three substrate Pi clean-install defects in one mechanism:
#
#   Issue 2  — Linux native bind mounts pass UIDs literally; the upstream
#              entrypoint expects to start as root so it can chown /opt/data.
#              We require `user: "0:0"` in compose.yaml and chown here from
#              the same root context.
#
#   Issue 9  — Runtime patches (SDK patch, webhook.py patch, jq install) live
#              in the container's writable layer and evaporate on
#              `docker compose up -d --force-recreate`. This entrypoint runs
#              every executable in `/opt/data/bin/entrypoint.d/` at every
#              boot, giving downstream seeds (gbrain, airbnb-manager, etc.)
#              a single canonical place to drop patch-re-apply scripts.
#
#   Issue 20 — Upstream entrypoint dispatcher uses `command -v "$1"` to
#              decide between `exec "$@"` and `exec hermes "$@"`. With
#              `$1 == "-p"` (e.g. `command: ["-p", "daniel", "gateway",
#              "run"]`), `command -v "-p"` returns 0 because -p is a flag
#              to `command` itself, and the dispatcher then runs
#              `exec -p ...` which bash's exec rejects. Here we always
#              prepend the hermes binary when args look like flags, so the
#              dispatcher never sees the ambiguous case.
#
# This script preserves the PR #3 (defect v2) contract:
#   - HERMES_UID = 10000 (image-baked container user)
#   - HERMES_GID = 10000
#   - HERMES_HOST_GID = host's primary gid, used as the directory group on
#     /opt/data via setgid so the host can read AND write the bind mount.
#
# It deliberately does NOT delegate back to the upstream entrypoint after
# its hooks run, because the upstream entrypoint would `chown -R
# $HERMES_UID:$HERMES_GID /opt/data` (10000:10000) and overwrite the
# host-gid group we just set. All upstream-entrypoint responsibilities
# (chown, mkdir runtime subdirs, privilege drop) are reimplemented here.

set -e

HERMES_CONTAINER_UID="${HERMES_UID:-10000}"
HERMES_CONTAINER_GID="${HERMES_GID:-10000}"
HERMES_HOST_GID="${HERMES_HOST_GID:-${HERMES_CONTAINER_GID}}"

log() {
  printf '[seed-entrypoint] %s\n' "$*"
}

# -- Step 1: pre-create runtime subdirs ---------------------------------------
# Hermes mkdir's these on first start; if /opt/data is a bind mount the host
# owns, that fails before we get a chance to chown. Pre-create as root.
mkdir -p \
  /opt/data/workspace \
  /opt/data/plugins \
  /opt/data/profiles \
  /opt/data/cron \
  /opt/data/sessions \
  /opt/data/logs \
  /opt/data/hooks \
  /opt/data/memories \
  /opt/data/skills \
  /opt/data/skins \
  /opt/data/plans \
  /opt/data/home \
  /opt/data/bin \
  /opt/data/bin/entrypoint.d

# -- Step 2: chown data tree --------------------------------------------------
# Owner = image-baked hermes UID (so the eventual gosu drop can write as
# owner). Group = HOST_GID (so the host user — which is in HOST_GID — can
# read AND write the same files via group bits). setgid on directories so
# new files inherit the directory's group.
chown -R "${HERMES_CONTAINER_UID}:${HERMES_HOST_GID}" /opt/data
find /opt/data -type d -exec chmod 2775 {} + 2>/dev/null || true
find /opt/data -type f -exec chmod 0664 {} + 2>/dev/null || true

# -- Step 3: run boot-time hooks ----------------------------------------------
# Downstream seeds drop executable scripts into /opt/data/bin/entrypoint.d/
# Examples that belong here:
#   01-sdk-patch.sh      — re-apply openai-python `output is None` patch
#   05-webhook-patch.sh  — re-apply INSECURE_NO_AUTH safety-rail bypass
#   10-gbrain-symlinks.sh — re-create /usr/local/bin/{bun,gbrain} symlinks
#   20-apt-jq.sh         — `command -v jq || apt-get install -y jq`
#
# Hooks run as root, in lexicographic order, before the privilege drop.
# A hook that exits non-zero aborts boot — make hooks idempotent and quiet
# on the happy path.
shopt -s nullglob
for hook in /opt/data/bin/entrypoint.d/*.sh; do
  if [ -x "$hook" ]; then
    log "running hook: $(basename "$hook")"
    if ! "$hook"; then
      log "hook failed: $hook (exit non-zero); aborting boot" >&2
      exit 1
    fi
  else
    log "skipping non-executable hook: $(basename "$hook")"
  fi
done
shopt -u nullglob

# -- Step 4: dispatch ---------------------------------------------------------
# Issue 20: if the first arg starts with `-` (e.g. `-p`, `--debug`),
# `command -v` returns 0 for builtin-flag-shaped strings, and a downstream
# `exec "$@"` then misinterprets the flag. Always prepend the hermes binary
# when args look like flags. Downstream services can also pass an absolute
# path to the hermes binary themselves; we don't double-wrap.
if [ $# -gt 0 ]; then
  first="$1"
  case "$first" in
    -*)
      log "dispatch: wrapping with hermes binary (first arg is a flag: ${first})"
      set -- /opt/hermes/.venv/bin/hermes "$@"
      ;;
  esac
fi

# -- Step 5: drop privileges --------------------------------------------------
# The upstream image ships gosu specifically for this. Drop to the canonical
# hermes user (image-baked UID 10000) while preserving the supplementary
# group we get from compose `group_add: HERMES_HOST_GID`.
log "dropping privileges → uid=${HERMES_CONTAINER_UID} gid=${HERMES_CONTAINER_GID} (+supp=${HERMES_HOST_GID})"
exec gosu "${HERMES_CONTAINER_UID}:${HERMES_CONTAINER_GID}" "$@"
