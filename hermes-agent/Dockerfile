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
#
# Why a derived image and not a runtime symlink / runtime apt-get:
#   The upstream image drops to the non-root `hermes` user before the compose
#   service command runs, so both `ln -sf ... /usr/local/bin/hermes` and
#   `apt-get install jq` at runtime fail with "Permission denied" — and even
#   when the operator works around with `docker exec -u 0:0`, those changes
#   evaporate the next time the container is recreated.
FROM nousresearch/hermes-agent

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
RUN ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes
USER hermes
