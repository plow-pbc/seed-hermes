#!/usr/bin/with-contenv sh
# 50-install-jq.sh — s6-overlay cont-init.d hook.
#
# nousresearch/hermes-agent:latest does NOT ship jq (verified 2026-05-27 on
# image digest sha256:fac5c1306df378959e15e70c171f94cf2643908a284012883d3d170f59f5682e),
# but downstream hostex-history-ingest scripts call jq heavily. Without
# this hook those scripts fail at runtime with `jq: command not found`,
# and a manual `docker exec -u 0:0 apt-get install jq` evaporates on every
# container recreate.
#
# This hook runs as root (cont-init.d is root-priv'd in s6-overlay) on
# every container start, before any supervised service. apt-get is
# idempotent — if jq is already present we exit fast.
#
# Mounted into the container by compose.yaml at:
#   /etc/cont-init.d/50-install-jq.sh
# The image's own cont-init.d entries (015-supervise-perms,
# 02-reconcile-profiles) still run — this hook just adds one more.
#
# Delete this file (and the compose volume) if a future image bakes
# jq in. The presence check + idempotent apt-get make the hook safe
# either way; the delete is purely a cleanup.
set -e

if command -v jq >/dev/null 2>&1; then
  exit 0
fi

echo "[seed-hermes/50-install-jq] jq missing — installing"
apt-get update >/dev/null
apt-get install -y --no-install-recommends jq >/dev/null
rm -rf /var/lib/apt/lists/*
echo "[seed-hermes/50-install-jq] jq installed: $(jq --version)"
