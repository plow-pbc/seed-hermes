#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."
./scripts/prepare.sh >/dev/null

tmp="${TMPDIR:-/tmp}/hermes-openai-codex-auth.$$"
trap 'rm -f "$tmp"' EXIT

echo "Starting Hermes ChatGPT OAuth. Complete the browser approval when the device page opens."

set +e
docker compose run --rm -T hermes auth add openai-codex 2>&1 | tee "$tmp" | awk '
function strip_ansi(s) {
  gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, "", s)
  return s
}
{
  clean = strip_ansi($0)
  if (clean ~ /https:\/\/auth\.openai\.com\/codex\/device/ && !seen_url) {
    seen_url = 1
    print ""
    print "Open this URL: https://auth.openai.com/codex/device"
    fflush()
  }
  if (clean ~ /2\. Enter this code:/) {
    want_code = 1
    next
  }
  if (want_code) {
    want_code = 0
    if (match(clean, /^[[:space:]]*([A-Z0-9]+-)*[A-Z0-9]+[[:space:]]*$/)) {
      code = clean
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", code)
      print "Enter this code: " code
      print ""
      fflush()
    }
  }
  if (clean ~ /Added openai-codex OAuth credential #[0-9]+/) {
    success = 1
  }
}
END {
  if (!success) {
    exit 1
  }
}
'
status=$?
set -e

if [ "$status" -ne 0 ]; then
  echo "OAuth did not complete successfully. Re-run this script after approving the browser flow." >&2
  exit "$status"
fi

if [ ! -f data/auth.json ]; then
  echo "Hermes reported OAuth success but data/auth.json was not found." >&2
  exit 1
fi

echo "ChatGPT OAuth credential stored in data/auth.json."
