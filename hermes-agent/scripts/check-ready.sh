#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."
dashboard_port="$(sed -n 's/^HERMES_DASHBOARD_PORT=//p' .env 2>/dev/null | tail -n 1)"
dashboard_port="${dashboard_port:-9119}"

if curl -fsS --max-time 3 "http://localhost:${dashboard_port}/" >/dev/null 2>&1; then
  echo "Hermes dashboard is reachable on http://localhost:${dashboard_port}/"
  exit 0
fi

if grep -Eq 'Gateway running with [0-9]+ platform|Gateway will continue running' data/logs/gateway.log 2>/dev/null; then
  echo "Hermes gateway readiness confirmed from data/logs/gateway.log."
  exit 0
fi

if docker compose logs --no-color --tail=300 hermes 2>/dev/null | grep -Eq 'Gateway running with [0-9]+ platform|Gateway will continue running'; then
  echo "Hermes gateway readiness confirmed from docker compose logs."
  exit 0
fi

echo "Hermes readiness probe failed: dashboard did not answer and no gateway-ready log line was found." >&2
exit 1
