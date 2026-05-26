# Thin derived image over nousresearch/hermes-agent.
#
# Purpose: bake /usr/local/bin/hermes -> /opt/hermes/.venv/bin/hermes at build
# time so `bash -lc 'hermes ...'` works for downstream seeds (gbrain installer,
# airbnb-manager courier sidecar, etc.).
#
# Why a derived image and not a runtime symlink:
#   The upstream image drops to the non-root `hermes` user before the compose
#   service command runs, so `ln -sf ... /usr/local/bin/hermes` at runtime
#   fails with "Permission denied" and the container restart-loops.
#
# This Dockerfile creates the symlink while still running as root, then
# restores the upstream USER directive.
FROM nousresearch/hermes-agent

USER root
RUN ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes
USER hermes
