#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."

cache="../.test-cache/hermes/auth.json"

usage() {
  echo "Usage: ./scripts/cache-auth-json.sh save|restore" >&2
  exit 2
}

case "${1:-}" in
  save)
    test -f data/auth.json || {
      echo "No data/auth.json to cache. Complete OAuth first." >&2
      exit 1
    }
    mkdir -p "$(dirname "$cache")"
    cp data/auth.json "$cache"
    chmod 600 "$cache"
    echo "Saved latest data/auth.json to ${cache}."
    ;;
  restore)
    test -f "$cache" || {
      echo "No cached auth.json at ${cache}." >&2
      exit 1
    }
    mkdir -p data
    cp "$cache" data/auth.json
    chmod 600 data/auth.json
    echo "Restored testing-only auth cache to data/auth.json."
    ;;
  *)
    usage
    ;;
esac
