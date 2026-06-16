#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."
./scripts/prepare.sh >/dev/null

# --- Reuse an existing ChatGPT `openai-codex` credential, non-interactively ----
#
# Hermes maintains its own Codex OAuth session in its auth store
# (data/auth.json inside HERMES_HOME). It already knows how to *adopt* a
# ChatGPT credential the OpenAI Codex CLI stored at ${CODEX_HOME:-~/.codex}/
# auth.json — see hermes_cli.auth._import_codex_cli_tokens /
# _recover_codex_tokens_from_cli. We reuse that native mechanism so the
# stored credential is written in Hermes' own schema (no hand-rolled copy or
# transform), then confirm `hermes auth status openai-codex` accepts it.
#
# If no valid credential is found, we fall through to the interactive
# device-code flow unchanged.
#
# A credential is "valid" only if it is parseable JSON with auth_mode
# "chatgpt" and a non-empty tokens.refresh_token; anything else falls through
# to the device flow rather than installing a broken credential. The
# container-side reader additionally rejects an expired access token that
# cannot be refreshed. No token value is ever echoed.

# Candidate credential file, in precedence order:
#   1. HERMES_OPENAI_CODEX_AUTH_FILE (explicit bypass)
#   2. ${CODEX_HOME:-$HOME/.codex}/auth.json (the Codex CLI's own store)
codex_auth_file="${HERMES_OPENAI_CODEX_AUTH_FILE:-${CODEX_HOME:-$HOME/.codex}/auth.json}"

# Run a command through the image's normal s6 entrypoint (no --entrypoint
# override) so it drops privileges to the HERMES_UID/HERMES_GID-remapped
# `hermes` user — bind-mounted writes to data/auth.json then land host-owned.
hermes_run() { docker compose run --rm -T "$@"; }

reuse_existing_credential() {
  # Idempotent: a Hermes auth store that already accepts openai-codex is a
  # no-op success, regardless of where it came from. Anchor on ": logged in"
  # so the negative status (": not logged in" / ": logged out") can't match.
  if hermes_run hermes auth status openai-codex 2>/dev/null | grep -q ': logged in'; then
    echo "ChatGPT OAuth already present; Hermes reports openai-codex logged in."
    return 0
  fi

  [ -f "$codex_auth_file" ] || return 1

  # Mount the candidate read-only and point Hermes' CLI-token reader at it via
  # CODEX_HOME. _recover_codex_tokens_from_cli reads ${CODEX_HOME}/auth.json
  # through _import_codex_cli_tokens (which enforces parseable JSON + non-empty
  # access/refresh + not-expired), then writes the Hermes auth store; it returns
  # falsy when the credential is absent/invalid. We add the conservative
  # auth_mode=="chatgpt" guard before adopting. On success Hermes writes its own
  # auth-store schema and `auth status` reports logged in.
  if ! hermes_run \
        -v "$codex_auth_file":/run/seed-codex/auth.json:ro \
        -e CODEX_HOME=/run/seed-codex \
        hermes /opt/hermes/.venv/bin/python - <<'PY'
import json, os, sys
from pathlib import Path
from hermes_cli.auth import _recover_codex_tokens_from_cli

auth_path = Path(os.environ["CODEX_HOME"]) / "auth.json"
try:
    auth_mode = (json.loads(auth_path.read_text()) or {}).get("auth_mode")
except Exception:
    sys.exit(1)
if auth_mode != "chatgpt":
    sys.exit(1)

sys.exit(0 if _recover_codex_tokens_from_cli("seed-hermes reuse of existing openai-codex credential") else 1)
PY
  then
    return 1
  fi

  if ! hermes_run hermes auth status openai-codex 2>/dev/null | grep -q ': logged in'; then
    echo "Adopted an existing credential but Hermes did not report openai-codex logged in." >&2
    return 1
  fi

  echo "Reused an existing ChatGPT openai-codex credential; Hermes reports it logged in."
  return 0
}

if reuse_existing_credential; then
  exit 0
fi

# --- Fallback: interactive device-code flow (unchanged) -----------------------

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
