# seed-hermes

## Purpose

`seed-hermes` is the gateway-agnostic Docker seed for running Hermes Agent locally. It gives a coding agent enough structure to create a `hermes-agent/` workspace, authenticate ChatGPT through Hermes' `openai-codex` OAuth flow, and start Hermes entirely in Docker with host-visible files under `./data`.

Natural file-creation requests land in `hermes-agent/data/workspace/` on the host. The container's process working directory and Hermes `terminal.cwd` are both `/opt/data/workspace`, so relative file writes and the agent's environment hint point at the same host-visible workspace.

`./scripts/prepare.sh` writes a per-checkout `COMPOSE_PROJECT_NAME` and `HERMES_CONTAINER_NAME` into `hermes-agent/.env`. That prevents a second local seed checkout from recreating or stopping another checkout's Hermes container. The default ports are still `8642` and `9119`, so parallel instances must also set distinct `HERMES_API_PORT` and `HERMES_DASHBOARD_PORT` values before starting Docker.

## Permission model — host + container share data/

The seed uses the upstream `nousresearch/hermes-agent:latest` image directly and lets its s6-overlay `/init` handle the bootstrap. Specifically, the image's `cont-init.d/01-hermes-setup` (the stage2-hook) does this on every container start:

1. Reads `HERMES_UID` and `HERMES_GID` from the environment, then `usermod -u $HERMES_UID hermes` and `groupmod -o -g $HERMES_GID hermes`. The in-container `hermes` user is now at the host user's UID/GID.
2. Targeted-chowns the hermes-owned subdirs of `/opt/data` (`cron`, `sessions`, `logs`, `hooks`, `memories`, `skills`, `skins`, `plans`, `workspace`, `home`, `profiles`) to the remapped uid/gid. Rootless-Podman-safe — `chown` failures don't abort.
3. The image's `main-wrapper.sh` (run as `/init`'s main program) drops privileges via `s6-setuidgid hermes` and exec's the command.

`prepare.sh` writes `HERMES_UID=$(id -u)` and `HERMES_GID=$(id -g)` to `hermes-agent/.env`. So after the stage2-hook remap, all bind-mounted writes land at host-owned UIDs — host and container share `data/` natively without any group_add, setgid, or chmod gymnastics.

Migration: `prepare.sh` rewrites stale `HERMES_UID=10000` / `HERMES_HOST_UID` / `HERMES_HOST_GID` keys (from earlier seed versions that used a derived image with a custom entrypoint) in place — running it on an existing checkout is enough.

## Why no derived image and no custom entrypoint

Earlier versions of this seed (PRs #2–#5) shipped:

- a derived `Dockerfile` (FROM nousresearch/hermes-agent) that baked in `jq`, a `/usr/local/bin/hermes` symlink, and two SDK patches for the Codex `'NoneType' object is not iterable` crash;
- a `seed-entrypoint.sh` that ran a `data/bin/entrypoint.d/*.sh` hook directory and `gosu`-dropped to the hermes user;
- a separate `hermes-init` Compose service (later folded into `seed-entrypoint.sh`) that chowned `/opt/data`.

The upstream image was re-pushed on 2026-05-27 with an s6-overlay rebuild that now does everything we patched:

| | Old image (PRs #3/#4/#5 targeted) | Current `:latest` |
|---|---|---|
| ENTRYPOINT | upstream `entrypoint.sh` (drops to hermes too early) | `/init` + `main-wrapper.sh` (s6-overlay) |
| `usermod` + chown | did not happen | stage2-hook (cont-init.d) |
| privilege drop | `gosu` | `s6-setuidgid` |
| `gosu` binary | present | **REMOVED** |
| `hermes` on `$PATH` | only via our symlink | `/opt/hermes/.venv/bin/` already on PATH |
| Codex `'NoneType'` SDK crash | required two build-time patches | fixed structurally |
| `jq` | absent (our Dockerfile installed) | **still absent** ← we ship a one-line cont-init hook |

Our seed-entrypoint.sh literally called `gosu` to drop privileges; against the new image it would fail-loud at boot. Rather than rev the wrapper, this version subtracts: no Dockerfile, no seed-entrypoint, no `user: "0:0"` override, no `group_add`. The compose file pulls `nousresearch/hermes-agent:latest` directly.

## Installing one missing package: `jq`

The new image still ships without `jq`, which downstream hostex-history-ingest scripts depend on. Rather than reintroduce a derived image just for one binary, the seed bind-mounts a single s6-overlay cont-init hook into the container:

```
./cont-init.d/50-install-jq.sh → /etc/cont-init.d/50-install-jq.sh
```

On every boot s6-overlay runs `/etc/cont-init.d/*` as root before any supervised service starts. `50-install-jq.sh` is idempotent — `command -v jq && exit 0` — and only runs `apt-get install -y --no-install-recommends jq` if the binary is missing. The image's own cont-init scripts (`015-supervise-perms`, `02-reconcile-profiles`) still run because we bind-mount a single file, not the whole directory.

If a future image bakes `jq` in, delete the hook file + the compose volume entry. The presence check makes the hook safe either way.

## Downstream seeds that need boot-time hooks

The old `data/bin/entrypoint.d/*.sh` directory has been retired (it was our entrypoint's invention; the upstream image doesn't know about it). Downstream seeds that need to re-apply runtime patches on every container start should follow the same pattern as `cont-init.d/50-install-jq.sh`:

1. Drop a script in your seed's own `cont-init.d/` directory.
2. Add a volume mount in your compose overlay:
   ```yaml
   volumes:
     - ./cont-init.d/<NN>-name.sh:/etc/cont-init.d/<NN>-name.sh:ro
   ```
3. Make the script idempotent. s6-overlay runs it as root before supervised services start, with `#!/usr/bin/with-contenv sh` to inherit the container's environment.

The seed is intentionally generic: platform-specific behavior lives in optional gateway seeds. This repo ships no gateway install scripts; gateway seeds own their own plugin files, host orchestration, and verification.

The Hermes dashboard is enabled by default at `http://localhost:9119`. It shows the local Hermes web UI for sessions, logs, configuration, plugins, and dashboard-backed tools. Inside Docker, the entrypoint binds it to `0.0.0.0` and passes the dashboard's `--insecure` flag; this is acceptable for the disposable local container because the published port is intended for loopback browsing. Do not expose `9119` beyond the trusted local machine.

The Docker compose defaults keep Hermes autonomous inside the disposable container: `HERMES_YOLO_MODE=1` lets the agent act without interactive approval prompts, and `GATEWAY_ALLOW_ALL_USERS=true` lets the gateway accept inbound platform users. Platform-specific seeds are responsible for their own access gates.

The OpenAI-compatible API server on `8642` is not enabled by default. It is only needed for external OpenAI-compatible clients such as Open WebUI or LibreChat, and should be configured with an API key when used.

## Running commands inside the container

`docker compose exec hermes <cmd>` defaults to **root** regardless of the image's `USER` directive. Any command that writes under `data/` (notably `hermes profile create <name>`) then leaves the resulting host bind-mounted files owned by `root:root`, which breaks every subsequent installer that tries to edit those files as the host user.

Always invoke `./scripts/hermes-exec.sh` instead. It is a thin wrapper that prepends `-u $HERMES_UID:$HERMES_GID` (from `.env`) to every `docker compose exec` call:

```sh
./scripts/hermes-exec.sh hermes profile create daniel
./scripts/hermes-exec.sh -T hermes profile list
./scripts/hermes-exec.sh hermes bash -lc 'hermes --version'
```

Downstream seeds (gbrain installer, airbnb-manager activation, etc.) should call `hermes-exec.sh` rather than raw `docker compose exec`.

## Reading config.yaml without host PyYAML

Clean substrate images often have no `python3-yaml` and can't `apt install` as a non-root user. The v2 substrate clean-install run hit this when the airbnb-manager preflight tried to parse `data/config.yaml` host-side: it silently treated the missing `import yaml` as "plugin not enabled" and aborted.

This seed ships `scripts/yaml-get.sh` which reads YAML keys via the **container's** Python (PyYAML is baked into the Hermes image):

```sh
./scripts/yaml-get.sh config.yaml model.provider         # -> openai-codex
./scripts/yaml-get.sh config.yaml plugins.enabled        # one item per line
./scripts/yaml-get.sh config.yaml plugins.enabled | grep -qx plow-chat-platform
```

Exit codes: `0` = found, `2` = key absent, `1` = file or YAML error. Downstream installers that today grep `data/config.yaml` host-side should switch to this helper.

## Other baked-in dependencies

`jq` is installed by the cont-init.d hook on first boot (see *Installing one missing package: `jq`* above). Re-pulling the image still requires `apt-get install` on boot, which is fast over a normal connection — but if you need it pre-baked, override the seed by building your own derived image.

`gh` (GitHub CLI) is **not** baked in. The seed and downstream installers always use the HTTPS-clone fallback (`git clone https://github.com/...`), so `gh` is purely optional convenience for human operators.

## Heads-up for downstream seeds

A few sharp edges this seed can't fix from its own scope; document them when you write installers that touch the Hermes container:

- **`hermes webhook subscribe` does not lazy-enable the webhook platform.** If a profile's `config.yaml` has no `platforms.webhook` block, `webhook subscribe` errors out with *"Webhook platform is not enabled."* Add the block first (or set `WEBHOOK_ENABLED=true`, `WEBHOOK_PORT=…`, `WEBHOOK_SECRET=…` in the profile `.env`) before calling `subscribe`. (Pi-substrate Issue 10.)
- **`docker compose exec hermes <cmd>` defaults to root.** Always go through `./scripts/hermes-exec.sh` so the command runs as the configured `HERMES_UID:HERMES_GID` and host bind-mounted writes stay host-owned.
- **`command: ["-p", "daniel", ...]` in a downstream compose file confuses the upstream entrypoint.** Either use the absolute hermes path (`command: ["/opt/hermes/.venv/bin/hermes", "-p", "daniel", "gateway", "run"]`) or, if the per-profile service inherits this seed's image, let `seed-entrypoint.sh` defensively wrap the args for you.

## DTU mock for E2E tests (opt-in)

When a downstream seed wants to drive end-to-end tests against a hostex-shaped webhook source, bring DTU up as a compose overlay rather than installing Flask + venv on the host:

```sh
docker compose -f compose.yaml -f compose.dtu.yaml up -d
```

DTU runs on the same compose network as Hermes, so the Hermes container reaches it at `http://dtu:8080` and the host reaches it at `http://localhost:${DTU_PORT:-8080}`. See `hermes-agent/dtu/README.md` for the implemented contract and how to swap in your own DTU implementation.
