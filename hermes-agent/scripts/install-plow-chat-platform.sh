#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."
./scripts/prepare.sh >/dev/null

pin="${PLOW_CHAT_PLUGIN_REF:-75f5ef2}"
base="${PLOW_CHAT_PLUGIN_RAW_BASE:-https://raw.githubusercontent.com/plow-pbc/seed-hermes-plow-chat/${pin}}"
dest="data/plugins/plow-chat-platform"

mkdir -p "$dest/ref/hermes-plugin/plow_chat"

fetch() {
  src="$1"
  out="$2"
  echo "Fetching ${src}"
  curl -fsSL "${base}/${src}" -o "${out}"
}

fetch "plugin.yaml" "$dest/plugin.yaml"
fetch "__init__.py" "$dest/__init__.py"
fetch "ref/hermes-plugin/plow_chat/adapter.py" "$dest/ref/hermes-plugin/plow_chat/adapter.py"
fetch "ref/hermes-plugin/plow_chat/__init__.py" "$dest/ref/hermes-plugin/plow_chat/__init__.py"
fetch "ref/hermes-plugin/plow_chat/plugin.yaml" "$dest/ref/hermes-plugin/plow_chat/plugin.yaml"

if ! grep -q '^[[:space:]]*-[[:space:]]*plow-chat-platform[[:space:]]*$' data/config.yaml; then
  tmp="${TMPDIR:-/tmp}/hermes-config.$$"
  awk '
    /^  enabled:[[:space:]]*\[\][[:space:]]*$/ {
      print "  enabled:"
      print "    - plow-chat-platform"
      next
    }
    /^  enabled:[[:space:]]*$/ {
      print
      print "    - plow-chat-platform"
      next
    }
    { print }
  ' data/config.yaml > "$tmp"
  mv "$tmp" data/config.yaml
fi

echo "Installed Plow Chat platform plugin at ${dest} and enabled plow-chat-platform in data/config.yaml."
