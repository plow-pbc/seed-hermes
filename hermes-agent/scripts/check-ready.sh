#!/usr/bin/env bash
#
# check-ready.sh — bounded readiness wait for the Hermes container.
#
# Probes three readiness signals (dashboard HTTP, gateway.log line, docker
# compose logs line) and returns on the first one that succeeds. The probes are
# wrapped in a bounded polling loop so callers inherit a first-boot-aware wait
# instead of hand-rolling their own poll: a fresh Pi's first boot runs a
# one-time recursive chown during the s6 stage2 hook that can take ~6 min on
# slow storage, during which none of the signals are up yet.
#
# Usage:
#     ./scripts/check-ready.sh [--timeout <seconds>]
#
#     --timeout <seconds>   Max seconds to wait for readiness (default 600).
#                           Also settable via HERMES_READY_TIMEOUT.
#
# Exits 0 on the first successful probe (printing the matching success line),
# or 1 if no signal appears before the timeout elapses.

set -euo pipefail

timeout="${HERMES_READY_TIMEOUT:-600}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)
      [ "$#" -ge 2 ] || { echo "check-ready: --timeout requires a value" >&2; exit 2; }
      timeout="$2"
      shift 2
      ;;
    --timeout=*)
      timeout="${1#*=}"
      shift
      ;;
    -h|--help)
      cat >&2 <<'USAGE'
Usage: check-ready.sh [--timeout <seconds>]

  --timeout <seconds>   Max seconds to wait for Hermes readiness (default 600).
                        Also settable via the HERMES_READY_TIMEOUT env var.

Polls the dashboard HTTP, gateway.log, and docker-compose-logs readiness
signals until one succeeds (exit 0) or the timeout elapses (exit 1).
USAGE
      exit 0
      ;;
    *)
      echo "check-ready: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$timeout" in '' | *[!0-9]*) echo "check-ready: timeout must be a non-negative integer (got '$timeout')" >&2; exit 2 ;; esac

cd -- "$(dirname "$0")/.."
dashboard_port="$(sed -n 's/^HERMES_DASHBOARD_PORT=//p' .env 2>/dev/null | tail -n 1)"
dashboard_port="${dashboard_port:-9119}"

probe_ready() {
  if curl -fsS --max-time 3 "http://localhost:${dashboard_port}/" >/dev/null 2>&1; then
    echo "Hermes dashboard is reachable on http://localhost:${dashboard_port}/"
    return 0
  fi

  if grep -Eq 'Gateway running with [0-9]+ platform|Gateway will continue running' data/logs/gateway.log 2>/dev/null; then
    echo "Hermes gateway readiness confirmed from data/logs/gateway.log."
    return 0
  fi

  if docker compose logs --no-color --tail=300 hermes 2>/dev/null | grep -Eq 'Gateway running with [0-9]+ platform|Gateway will continue running'; then
    echo "Hermes gateway readiness confirmed from docker compose logs."
    return 0
  fi

  return 1
}

start="$(date +%s)"
next_progress=$(( start + 60 ))

while :; do
  if probe_ready; then
    exit 0
  fi

  now="$(date +%s)"
  elapsed=$(( now - start ))
  if [ "$elapsed" -ge "$timeout" ]; then
    break
  fi

  if [ "$now" -ge "$next_progress" ]; then
    echo "still waiting for Hermes readiness… (${elapsed}s/${timeout}s elapsed)" >&2
    next_progress=$(( now + 60 ))
  fi

  # Poll every 10s, but never overshoot the deadline: cap the final sleep at the
  # remaining budget so --timeout is honored to the second (elapsed < timeout here).
  remaining=$(( timeout - elapsed ))
  sleep "$(( remaining < 10 ? remaining : 10 ))"
done

echo "Hermes readiness probe failed after ${timeout}s: dashboard did not answer and no gateway-ready log line was found." >&2
exit 1
