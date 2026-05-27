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
COPY entrypoint/seed-entrypoint.sh /usr/local/bin/seed-entrypoint.sh
RUN chmod +x /usr/local/bin/seed-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/seed-entrypoint.sh"]
# Default to running the gateway; downstream services override `command:`.
CMD ["/opt/hermes/.venv/bin/hermes", "gateway", "run"]
# USER stays at root: compose.yaml expects to start as root (user: "0:0")
# so seed-entrypoint.sh can chown the bind mount and run boot hooks before
# dropping to the hermes user via gosu. See entrypoint/seed-entrypoint.sh.
