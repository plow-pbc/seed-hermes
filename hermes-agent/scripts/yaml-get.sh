#!/usr/bin/env bash
#
# yaml-get.sh — read a YAML key from a data/ file via the container's Python.
#
# Removes the host-PyYAML dependency that broke airbnb-manager plugin
# preflight on clean substrates (defect #31). The Hermes container ships
# with PyYAML installed; this script execs into it to read keys with proper
# YAML parsing, so callers don't have to grep through inline-list quirks.
#
# Usage:
#     ./scripts/yaml-get.sh <relative-path-under-/opt/data> <dotted.key>
#
# Examples:
#     # Read scalar:
#     ./scripts/yaml-get.sh config.yaml model.provider
#     #=> openai-codex
#
#     # Read list (one item per line):
#     ./scripts/yaml-get.sh config.yaml plugins.enabled
#     #=> plow-chat-platform
#
#     # Check if a value is in a list (exit code only):
#     ./scripts/yaml-get.sh config.yaml plugins.enabled | grep -qx plow-chat-platform
#
# Exit codes:
#     0 — key found, value printed
#     1 — generic error (file missing, malformed YAML)
#     2 — key not present in the document
#
# The script runs inside the already-running `hermes` service container
# (`docker compose exec`), so it does not start a fresh container per call
# and is cheap enough to use in preflight loops.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <relative-path-under-/opt/data> <dotted.key>" >&2
  exit 1
fi

rel_path="$1"
key="$2"

cd -- "$(dirname "$0")/.."

exec docker compose exec -T hermes /opt/hermes/.venv/bin/python - "$rel_path" "$key" <<'PY'
import os, sys, yaml

rel_path, key = sys.argv[1], sys.argv[2]
path = os.path.join("/opt/data", rel_path)
try:
    with open(path) as f:
        doc = yaml.safe_load(f) or {}
except FileNotFoundError:
    print(f"yaml-get: {path} not found", file=sys.stderr)
    sys.exit(1)
except yaml.YAMLError as e:
    print(f"yaml-get: malformed yaml in {path}: {e}", file=sys.stderr)
    sys.exit(1)

node = doc
for part in key.split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(2)

if isinstance(node, list):
    for item in node:
        print(item)
elif isinstance(node, dict):
    # Print top-level dict keys (caller can recurse if needed).
    for k in node:
        print(k)
elif node is None:
    pass
else:
    print(node)
PY
