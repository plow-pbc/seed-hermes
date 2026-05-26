#!/usr/bin/env bash
#
# hermes-exec.sh — `docker compose exec` wrapper that always runs as the
# configured HERMES_UID:HERMES_GID.
#
# Why this exists: `docker compose exec hermes <cmd>` defaults to root,
# regardless of the image's USER directive. When commands like `hermes profile
# create <name>` are executed that way they create host bind-mounted profile
# directories owned by `root:root`, which then break every downstream installer
# that tries to write into `data/profiles/<name>/plugins/` as the host user.
#
# Always invoke this wrapper instead of bare `docker compose exec hermes ...`.
# Downstream seeds (gbrain installer, airbnb-manager activation, etc.) should
# use this script too.
#
# Usage:
#     ./scripts/hermes-exec.sh hermes profile create daniel
#     ./scripts/hermes-exec.sh bash -lc 'hermes profile list'
#     ./scripts/hermes-exec.sh -T hermes profile list   # non-TTY mode
#
# Any leading flags before the command (e.g. -T, --workdir DIR) are passed
# through to `docker compose exec` unchanged; the `-u` flag is always
# prepended from the scaffold .env file.

set -euo pipefail

cd -- "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "hermes-exec: .env missing — run ./scripts/prepare.sh first" >&2
  exit 1
fi

uid="$(sed -n 's/^HERMES_UID=//p' .env | tail -n 1)"
gid="$(sed -n 's/^HERMES_GID=//p' .env | tail -n 1)"

if [ -z "$uid" ] || [ -z "$gid" ]; then
  echo "hermes-exec: HERMES_UID / HERMES_GID missing from .env — run ./scripts/prepare.sh" >&2
  exit 1
fi

exec docker compose exec -u "${uid}:${gid}" "$@"
