#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."
./scripts/prepare.sh >/dev/null

pin="${PLOW_CHAT_PLUGIN_REF:-9266e3d4fa74be6410793bc0fbedc1484aff352d}"
# Follow-up after the rewrite PR merges: re-pin this default to the merged main SHA.
base="${PLOW_CHAT_PLUGIN_RAW_BASE:-https://raw.githubusercontent.com/plow-pbc/seed-hermes-plow-chat/${pin}}"
dest="data/plugins/plow-chat-platform"
files="
plugin.yaml
__init__.py
ref/hermes-plugin/plow_chat/adapter.py
ref/hermes-plugin/plow_chat/__init__.py
ref/hermes-plugin/plow_chat/plugin.yaml
"

mkdir -p "$dest/ref/hermes-plugin/plow_chat"

fetch_remote() {
  src="$1"
  out="$2"
  echo "Fetching ${src}"
  curl -fsSL "${base}/${src}" -o "${out}"
}

copy_local() {
  src="$1"
  out="$2"
  local_dir="${PLOW_CHAT_PLUGIN_LOCAL_DIR%/}"
  test -f "${local_dir}/${src}" || {
    echo "Missing ${src} in PLOW_CHAT_PLUGIN_LOCAL_DIR=${PLOW_CHAT_PLUGIN_LOCAL_DIR}" >&2
    exit 1
  }
  echo "Copying ${src} from local testing checkout"
  cp "${local_dir}/${src}" "${out}"
}

for src in $files; do
  out="${dest}/${src}"
  mkdir -p "$(dirname "$out")"
  if [ -n "${PLOW_CHAT_PLUGIN_LOCAL_DIR:-}" ]; then
    case "$PLOW_CHAT_PLUGIN_LOCAL_DIR" in
      /*) copy_local "$src" "$out" ;;
      *)
        echo "PLOW_CHAT_PLUGIN_LOCAL_DIR must be an absolute path." >&2
        exit 1
        ;;
    esac
  else
    fetch_remote "$src" "$out"
  fi
done

if ! grep -q '^[[:space:]]*-[[:space:]]*plow-chat-platform[[:space:]]*$' data/config.yaml; then
  tmp="${TMPDIR:-/tmp}/hermes-config.$$"
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function emit_inline_items(items,    n, a, i, item) {
      n = split(items, a, ",")
      for (i = 1; i <= n; i++) {
        item = trim(a[i])
        gsub(/^["'\'']|["'\'']$/, "", item)
        if (item != "" && item != "plow-chat-platform") {
          print "    - " item
        }
      }
      print "    - plow-chat-platform"
    }
    /^  enabled:[[:space:]]*\[\][[:space:]]*$/ {
      print "  enabled:"
      print "    - plow-chat-platform"
      next
    }
    /^  enabled:[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      line = $0
      sub(/^  enabled:[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      print "  enabled:"
      emit_inline_items(line)
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
