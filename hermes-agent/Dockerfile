# Thin derived image over nousresearch/hermes-agent.
#
# Purpose:
#   1. Bake /usr/local/bin/hermes -> /opt/hermes/.venv/bin/hermes at build
#      time so `bash -lc 'hermes ...'` works for downstream seeds (gbrain
#      installer, airbnb-manager courier sidecar, etc.).
#   2. Install `jq` into the image layer so the hostex-history-ingest scripts
#      (defect #21) survive `docker compose down/up` cycles. Installing jq
#      at runtime via `apt-get` inside an exec'd shell loses it on the next
#      container recreate, and downstream installers can't reliably re-add
#      it because the hermes user is non-root.
#   3. Install `seed-entrypoint.sh` as the container ENTRYPOINT. It chowns
#      the bind-mounted data, runs `/opt/data/bin/entrypoint.d/*.sh` hooks
#      (the canonical patch-re-apply mechanism for downstream seeds), and
#      gosu-drops to the image-baked hermes user. See entrypoint/
#      seed-entrypoint.sh for the full rationale (covers Pi-substrate
#      Issues 2, 9, 20).
#   4. Patch the Codex "'NoneType' object is not iterable" crash into the
#      image layer (see the RUN block below). Baked at build time rather than
#      run as an entrypoint.d hook (#3) on purpose: it must fail loud if a
#      base-image bump moves the patched line, and it's a general SDK bug
#      independent of any downstream seed's boot hooks.
#
# Why a derived image and not a runtime symlink / runtime apt-get / runtime
# entrypoint patch: the upstream image drops to the non-root `hermes` user
# before the compose service command runs, so all three operations fail
# with "Permission denied" at runtime — and even when an operator works
# around with `docker exec -u 0:0`, those changes evaporate the next time
# the container is recreated.
FROM nousresearch/hermes-agent

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
RUN ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes

# --- TEMPORARY: Codex "'NoneType' object is not iterable" patch (substrate blocker) ---
# chatgpt.com/backend-api/codex emits a `response.completed` SSE event with the
# `output` field OMITTED -> pydantic sets response.output = None -> the
# openai-python SDK's parse_response() runs `for output in response.output:` ->
# TypeError: 'NoneType' object is not iterable, crashing EVERY Codex chat turn
# (verified on gpt-5.5, gpt-5.3-codex, gpt-5.4-mini). Live traceback + analysis
# in /tmp/UPSTREAM-BUG.md (origin doc, from the parallel Pi install repro).
#
# Two build-time patches, each idempotent AND fail-loud (a base-image bump that
# moves either line breaks the build instead of silently regressing):
#   (a) openai-python SDK 2.24.0  — load-bearing: guard None before iterating.
#   (b) hermes-agent 0.14.0       — defensive: backfill output=None, not just [].
# (a) is what unblocks Codex; (b) hardens Hermes' existing empty-output backfill.
#
# PINNED BUG VERSIONS (re-review when bumping the base image):
#   openai-python            == 2.24.0   (openai/lib/_parsing/_responses.py)
#   nousresearch/hermes-agent == 0.14.0  (run_agent.py, two _run_codex_stream guards)
# TODO(remove): delete this whole block once upstream fixes land and we pin a
# fixed openai-python release. Follow-up tasks (not done here): file PRs against
# openai/openai-python (primary) and nousresearch/hermes-agent (defensive).
RUN set -eu; \
    f="$(ls /opt/hermes/.venv/lib/python*/site-packages/openai/lib/_parsing/_responses.py 2>/dev/null | head -n1)"; \
    old='    for output in response.output:'; \
    new='    for output in (response.output or []):'; \
    if [ -z "$f" ] || [ ! -f "$f" ]; then \
      echo "ERROR [codex-patch a]: openai _responses.py not found under /opt/hermes/.venv (openai-python layout changed?)" >&2; exit 1; \
    elif grep -qF "$new" "$f"; then \
      echo "[codex-patch a] openai SDK already patched: $f"; \
    elif grep -qF "$old" "$f"; then \
      sed -i 's|    for output in response\.output:|    for output in (response.output or []):|' "$f"; \
      grep -qF "$new" "$f" || { echo "ERROR [codex-patch a]: sed ran but verification failed in $f" >&2; exit 1; }; \
      echo "[codex-patch a] openai SDK patched: $f"; \
    else \
      echo "ERROR [codex-patch a]: expected line not found in $f" >&2; \
      echo "  expected literal: [$old]" >&2; \
      echo "  pinned bug version: openai-python 2.24.0 — upstream moved/fixed this line; review before bumping the base image." >&2; \
      exit 1; \
    fi
RUN set -eu; \
    f=/opt/hermes/run_agent.py; \
    old='                    if isinstance(_out, list) and not _out:'; \
    new='                    if _out is None or (isinstance(_out, list) and not _out):'; \
    if [ ! -f "$f" ]; then \
      echo "ERROR [codex-patch b]: $f not found" >&2; exit 1; \
    elif grep -qF "$new" "$f"; then \
      echo "[codex-patch b] hermes run_agent.py already patched"; \
    elif grep -qF "$old" "$f"; then \
      n="$(grep -cF "$old" "$f")"; \
      sed -i 's|                    if isinstance(_out, list) and not _out:|                    if _out is None or (isinstance(_out, list) and not _out):|g' "$f"; \
      grep -qF "$new" "$f" || { echo "ERROR [codex-patch b]: sed ran but verification failed in $f" >&2; exit 1; }; \
      echo "[codex-patch b] hermes run_agent.py patched ($n guard(s))"; \
    else \
      echo "ERROR [codex-patch b]: expected guard not found in $f" >&2; \
      echo "  expected literal: [$old]" >&2; \
      echo "  pinned bug version: nousresearch/hermes-agent 0.14.0 — upstream moved/fixed this guard; review before bumping the base image." >&2; \
      exit 1; \
    fi
COPY entrypoint/seed-entrypoint.sh /usr/local/bin/seed-entrypoint.sh
RUN chmod +x /usr/local/bin/seed-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/seed-entrypoint.sh"]
# Default to running the gateway; downstream services override `command:`.
CMD ["/opt/hermes/.venv/bin/hermes", "gateway", "run"]
# USER stays at root: compose.yaml expects to start as root (user: "0:0")
# so seed-entrypoint.sh can chown the bind mount and run boot hooks before
# dropping to the hermes user via gosu. See entrypoint/seed-entrypoint.sh.
