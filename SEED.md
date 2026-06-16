# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

### Host tools

- Docker with Compose v2 support MUST be available on the host; if the Compose plugin is absent, the installer installs it.
- A POSIX shell and `curl` MUST be available on the host.
- A ChatGPT account capable of completing Hermes' `openai-codex` OAuth device-code flow MUST be available when model auth is performed.

### Optional platform gateway

- `https://github.com/plow-pbc/seed-hermes-plow-chat.git` is an OPTIONAL dependency: an iMessage/RCS platform gateway, built on the Plow Chat API, that lets the user chat with Hermes from their phone.

## Objects

### Hermes agent folder

- `hermes-agent/` is the Docker-only host workspace for Hermes Agent.
- `hermes-agent/compose.yaml` MUST define one service named `hermes` that uses the upstream image directly (`image: nousresearch/hermes-agent:latest`). It MUST NOT `build:` a derived image, MUST NOT set `entrypoint:`, MUST NOT set `user:`, and MUST NOT use `group_add:`. The image's s6-overlay `ENTRYPOINT` (`/init` + `/opt/hermes/docker/main-wrapper.sh`) and its `cont-init.d/01-hermes-setup` (the stage2-hook) are the canonical bootstrap path; overriding any of them re-introduces the v1/PR-#3 permission-model drift.
- The seed MUST NOT ship a `hermes-agent/Dockerfile`. The previous derived image (PRs #2/#3/#5) baked in the `/usr/local/bin/hermes` symlink, `jq`, and two Codex `'NoneType'` SDK patches. As of the 2026-05-27 `nousresearch/hermes-agent:latest` re-push, `hermes` is already on `$PATH` at `/opt/hermes/.venv/bin/hermes`, the Codex crash is fixed structurally, and the only remaining gap (`jq`) is handled by a single cont-init.d hook (see below).
- The seed MUST NOT ship a `hermes-agent/entrypoint/seed-entrypoint.sh`. The s6-overlay-based image now does what that wrapper did natively: stage2-hook handles `usermod` + targeted `chown` of `/opt/data` hermes-owned subdirs, and `main-wrapper.sh` drops privileges via `s6-setuidgid`. The previous wrapper called `gosu` which has been removed from the new image — a residual wrapper would fail-loud at boot.
- `hermes-agent/cont-init.d/50-install-jq.sh` MUST exist, MUST be executable, MUST start with `#!/usr/bin/with-contenv sh`, MUST be idempotent (exit 0 if `command -v jq` succeeds), and MUST be bind-mounted by `compose.yaml` to `/etc/cont-init.d/50-install-jq.sh:ro`. This is the only seed-owned cont-init hook — it covers the one binary the image still lacks. The bind mount MUST target a single file, NOT the parent directory, so the image's own `cont-init.d/015-supervise-perms` and `cont-init.d/02-reconcile-profiles` are not shadowed.
- Downstream seeds that need their own boot-time hooks SHOULD follow the same pattern: drop a script in their seed's `cont-init.d/` directory and bind-mount the single file into `/etc/cont-init.d/`. They MUST NOT rely on the retired `/opt/data/bin/entrypoint.d/` directory — that mechanism died with `seed-entrypoint.sh`.
- `hermes-agent/scripts/prepare.sh` MUST write a per-checkout `COMPOSE_PROJECT_NAME` and `HERMES_CONTAINER_NAME` into `hermes-agent/.env`; multiple seed checkouts MUST NOT share the default Compose project/container identity.
- `hermes-agent/compose.yaml` MUST set the container working directory to `/opt/data/workspace`, matching `terminal.cwd`, so agent environment hints and file tools agree on the host-visible default workspace.
- `hermes-agent/compose.yaml` MUST mount `./data` as the whole `/opt/data` volume.
- `hermes-agent/compose.yaml` MUST expose container ports `8642` and `9119`, with host ports overridable by `HERMES_API_PORT` and `HERMES_DASHBOARD_PORT`.
- `hermes-agent/compose.yaml` MUST set `HERMES_DASHBOARD=1` so `http://localhost:9119` serves the Hermes dashboard by default.
- The dashboard shows the local Hermes web UI for sessions, logs, configuration, plugins, and dashboard-backed tools. The image's dashboard run script binds it to `0.0.0.0` (so Docker can port-map `9119` to the host), where the dashboard's OAuth auth gate fails closed unless a `DashboardAuthProvider` is registered. `--insecure` is opt-in via the `HERMES_DASHBOARD_INSECURE` env var, so `compose.yaml` MUST set `HERMES_DASHBOARD_INSECURE=1` to skip that gate and let the dashboard bind; this is acceptable only for a disposable local container intended for loopback browsing.
- `hermes-agent/compose.yaml` MUST NOT enable the OpenAI-compatible API server on `8642` by default; external OpenAI-compatible clients require explicit API-server configuration and a key.
- `hermes-agent/compose.yaml` intentionally sets `HERMES_YOLO_MODE=1` so Hermes can act autonomously without approval prompts inside the disposable container.
- `hermes-agent/compose.yaml` intentionally sets `GATEWAY_ALLOW_ALL_USERS=true`; platform-specific seeds remain responsible for their own access boundary.
- `hermes-agent/.env` is local runtime state generated by `hermes-agent/scripts/prepare.sh`. It MUST set `COMPOSE_PROJECT_NAME`, `HERMES_CONTAINER_NAME`, `HERMES_UID`, and `HERMES_GID`, and MUST NOT be committed. It MUST NOT contain `HERMES_HOST_UID` or `HERMES_HOST_GID` — those keys were retired with `seed-entrypoint.sh`.
- `HERMES_UID` and `HERMES_GID` in `.env` MUST equal the host user's `id -u` and `id -g`. The image's stage2-hook reads these and `usermod`s the in-container `hermes` user to the host UID/GID before chowning hermes-owned subdirs of `/opt/data`. After remap, all bind-mounted writes land at host-owned UIDs, so host and container share `data/` without group_add / setgid / chmod gymnastics.
- `hermes-agent/scripts/prepare.sh` MUST be idempotent and MUST migrate stale `.env` files. Specifically it MUST: (a) rewrite `HERMES_UID=10000` and `HERMES_GID=10000` (the PR-#3/PR-#4 values) to `$(id -u)` / `$(id -g)`; (b) delete `HERMES_HOST_UID=*` and `HERMES_HOST_GID=*` entries (no longer needed). Running it on any earlier seed checkout MUST converge `.env` to the current contract.
- `hermes-agent/scripts/hermes-exec.sh` MUST wrap `docker compose exec` and always prepend `-u $HERMES_UID:$HERMES_GID` from `.env`. Any command this seed or a downstream seed runs inside the Hermes container — particularly `hermes profile create` — MUST go through this wrapper so it does not run as `root` and leave host bind-mounted files owned by `root:root`.
- `hermes-agent/scripts/yaml-get.sh` MUST exist, MUST read YAML keys from files under `/opt/data` via the container's Python (which has `PyYAML` baked in), and downstream seeds that today parse `data/config.yaml` host-side SHOULD switch to this helper so they do not require host `python3-yaml`.

### Hermes data folder

- `hermes-agent/data/` is `HERMES_HOME` inside the container.
- `hermes-agent/data/config.yaml` MUST exist before first boot.
- `hermes-agent/data/config.yaml` MUST set `terminal.cwd: /opt/data/workspace`.
- The container process cwd and `terminal.cwd` MUST both point at `/opt/data/workspace`; natural file-creation requests should therefore use `hermes-agent/data/workspace/` on the host without first trying `/opt/hermes`.
- `hermes-agent/data/config.yaml` MUST set `model.provider: openai-codex` and a default model.
- `hermes-agent/data/config.yaml` MUST NOT set `model.base_url` for `openai-codex`; Hermes uses its runtime default.
- `hermes-agent/data/workspace/` is the host-visible Hermes working directory.
- `hermes-agent/data/plugins/` is the host-visible plugin directory.
- `hermes-agent/data/.env` holds platform runtime values. It MUST NOT be committed.
- `hermes-agent/data/auth.json` is written by Hermes after ChatGPT OAuth succeeds. It MUST NOT be committed.

### Platform gateway

- A platform gateway is OPTIONAL.
- This seed MUST NOT ship gateway install scripts or gateway-specific plugin files.
- Gateway plugins live under `hermes-agent/data/plugins/<name>/` on the host, which is `/opt/data/plugins/<name>/` inside the container.
- If a platform gateway is installed by its own seed, `hermes-agent/data/config.yaml` MUST enable that plugin under `plugins.enabled`.
- Platform-specific configuration, host orchestration, pairing, access control, and verification belong to the gateway seed.

## Actions

### Hermes scaffold is prepared

The agent prepares the Docker-only Hermes workspace without requiring host-local Hermes or Python.

1. Change into `hermes-agent/`.
2. Run `./scripts/prepare.sh`.
3. Confirm `data/config.yaml`, `data/workspace/`, `data/plugins/`, `data/profiles/`, `.env`, and `data/.env` exist. (The `data/{cron,sessions,logs,hooks,memories,skills,skins,plans,home}/` runtime subdirs are NOT created here; the image's stage2-hook creates them under the remapped UID at first boot.)
4. Confirm `.env` contains `HERMES_UID=$(id -u)` and `HERMES_GID=$(id -g)` (the host user's IDs) and does NOT contain `HERMES_HOST_UID` / `HERMES_HOST_GID`.
5. Do not overwrite an existing `data/config.yaml`.

### Platform gateway choice is handled

The agent asks the user whether they want a platform gateway.

1. Ask: "Want a platform gateway? I can follow the optional iMessage/RCS gateway seed so you can chat with Hermes from your phone."
2. If the user declines, leave `plugins.enabled` unchanged and continue with gateway-less Hermes.
3. If the user chooses a platform gateway, follow the optional dependency seed from `## Dependencies`.
4. After the gateway seed completes, confirm any installed plugin exists under `data/plugins/<name>/` and that `data/config.yaml` enables the plugin manifest name.
5. Do not run gateway-specific shell scripts from this seed; the gateway seed owns that path.

### ChatGPT OAuth is completed

The agent drives Hermes' `openai-codex` OAuth device-code flow headlessly.

1. Run `./scripts/auth-openai-codex.sh`, which invokes `docker compose run --rm -T hermes auth add openai-codex`.
2. Relay `https://auth.openai.com/codex/device` to the user.
3. Relay the code printed on the line after `2. Enter this code:`.
4. Wait for the user to complete browser approval.
5. Confirm Hermes prints `Added openai-codex OAuth credential #<N>` and writes `data/auth.json`.
6. Do not build provider introspection, `.env` BYOK branching, or automation around `hermes model`.
7. Advanced users who want a different provider MAY run `docker compose run --rm hermes model` themselves in a terminal.

### Hermes is started

The agent starts Hermes in Docker.

1. Change into `hermes-agent/`.
2. Run `docker compose up -d`.
3. Probe readiness with `./scripts/check-ready.sh` or inspect logs for a gateway-ready line.
4. Browse `http://localhost:9119` and confirm the Hermes dashboard loads.
5. Confirm a file written from inside the container appears under `data/workspace/` and is editable by the host user.
6. If ports conflict, set `HERMES_API_PORT` or `HERMES_DASHBOARD_PORT` in `hermes-agent/.env` and restart.

### DTU mock service (optional)

- `hermes-agent/compose.dtu.yaml` is an OPTIONAL compose overlay that brings up a Flask-based hostex mock (DTU) on the same compose network as Hermes.
- DTU MUST NOT be brought up by default; it is opt-in via `docker compose -f compose.yaml -f compose.dtu.yaml up -d`.
- DTU MUST be reachable from the Hermes container at `http://dtu:8080` (compose-network DNS) so downstream seeds do not have to rely on `host.docker.internal` (which does not resolve inside Docker-in-Docker substrates).
- The DTU build context lives at `hermes-agent/dtu/`. The shipped `app.py` implements the minimal hostex contract documented in `hermes-agent/dtu/README.md`; it MAY be replaced with a richer implementation provided the same endpoint surface is preserved.

## Verification

1. From `hermes-agent/`, run `./scripts/prepare.sh`; `.env` MUST contain `COMPOSE_PROJECT_NAME`, `HERMES_CONTAINER_NAME`, and the host user's `HERMES_UID` and `HERMES_GID`.
2. From `hermes-agent/`, run `./scripts/verify.sh`; it MUST print `seed-hermes scaffold verifies`.
3. From `hermes-agent/`, run `docker compose up -d` and then `./scripts/check-ready.sh`; the dashboard readiness probe or a Hermes gateway-ready log probe MUST pass. Parallel checkouts MUST also use distinct `HERMES_API_PORT` and `HERMES_DASHBOARD_PORT` values.
4. From `hermes-agent/`, fetch `http://localhost:${HERMES_DASHBOARD_PORT:-9119}/`; it MUST return dashboard HTML.
5. From `hermes-agent/`, write a smoke file from inside the running container to `/opt/data/workspace/`; the same file MUST appear in `data/workspace/` and the host user MUST be able to edit it.
6. Secret hygiene MUST pass: `hermes-agent/.env`, `hermes-agent/data/.env`, and `hermes-agent/data/auth.json` are git-ignored; tracked files MUST NOT contain GitHub token env vars, GitHub PAT prefixes, model keys, platform secret values, or OAuth credentials; runtime logs MUST NOT be copied into commits or reports.
7. If a platform gateway was chosen, run that gateway seed's verification.
8. If the platform gateway was declined, Hermes MUST still boot and pass the readiness probe without any platform plugin enabled.

Maintainers SHOULD also run `bash ../seed/ref/verify.sh .` from the repo root when a sibling checkout of the SEED convention repo is available; it MUST print `tree conforms`.

## Feedback

(default)
