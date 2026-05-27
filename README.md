# seed-hermes

## Purpose

`seed-hermes` is the gateway-agnostic Docker seed for running Hermes Agent locally. It gives a coding agent enough structure to create a `hermes-agent/` workspace, authenticate ChatGPT through Hermes' `openai-codex` OAuth flow, and start Hermes entirely in Docker with host-visible files under `./data`.

Natural file-creation requests land in `hermes-agent/data/workspace/` on the host. The container's process working directory and Hermes `terminal.cwd` are both `/opt/data/workspace`, so relative file writes and the agent's environment hint point at the same host-visible workspace.

`./scripts/prepare.sh` writes a per-checkout `COMPOSE_PROJECT_NAME` and `HERMES_CONTAINER_NAME` into `hermes-agent/.env`. That prevents a second local seed checkout from recreating or stopping another checkout's Hermes container. The default ports are still `8642` and `9119`, so parallel instances must also set distinct `HERMES_API_PORT` and `HERMES_DASHBOARD_PORT` values before starting Docker.

## Permission model — host + container share data/

The upstream `nousresearch/hermes-agent` image runs its runtime as `hermes` (UID/GID **10000**), and the container writes the bind-mounted `./data/` tree heavily (sessions, cron, logs, hooks, memories, profiles, ...). The host also needs to read and edit some of those files (`.env`, `config.yaml`, profile env files for installers). The seed makes those two needs coexist without `sudo chown` at every install phase:

- `prepare.sh` writes `HERMES_UID=10000`, `HERMES_GID=10000` to `hermes-agent/.env` (canonical container user — downstream sidecars and installers read these and target the correct user) and records `HERMES_HOST_GID` separately.
- `compose.yaml` sets `user: "0:0"` on the `hermes` service so the container starts as root. The derived image's `ENTRYPOINT` is `seed-entrypoint.sh` (see `entrypoint/seed-entrypoint.sh`), which:
  - pre-creates `data/{workspace,plugins,profiles,cron,sessions,logs,hooks,memories,skills,skins,plans,home}` so Hermes never has to `mkdir` against a parent it doesn't own;
  - `chown -R 10000:HERMES_HOST_GID /opt/data`;
  - `chmod 2775` on directories (setgid + group rwx), `chmod 0664` on files;
  - runs any executable under `/opt/data/bin/entrypoint.d/*.sh` (the canonical patch-re-apply hook, see below);
  - `gosu`-drops to the image-baked hermes user and exec's the command.
- The `hermes` service adds `group_add: [HERMES_HOST_GID]`. New files Hermes creates inherit `HERMES_HOST_GID` via the setgid bit, end up mode `0664`, and are group-readable AND group-writable by the host user.

Net effect: the v2 substrate run's recurring `Permission denied` / `sudo chown -R 10000:10000 data` / `sudo chmod -R a+rwX data` pattern at Phase 2, 2.5, 4, 6, 8 is replaced by a single `prepare.sh` + `docker compose up -d` from a clean checkout, on **Linux native Docker** as well as macOS Docker Desktop.

(Previous versions of this seed used a separate `hermes-init` Compose service to do the chown. The Pi clean-install run showed that approach fought the upstream entrypoint's intended Linux flow: the upstream entrypoint *expects* to start as root so it can do its own privilege handling. Folding the chown into our own root-side `seed-entrypoint.sh` and setting `user: "0:0"` aligns with that expectation.)

If you ever see `Permission denied` on a path under `data/` after this seed is up, `docker compose restart hermes` will re-run the chown idempotently — there is never a reason to `sudo` from the host.

## Boot-time hooks for patches and runtime fixes

Downstream seeds occasionally need to patch files under `/opt/hermes/*` (the runtime), install a missing system package, or re-create a symlink that lives in the container's writable layer. Doing those imperatively via `docker exec -u 0:0` works once — but on the next `docker compose up -d --force-recreate` the writable layer is gone and every patch evaporates.

The seed provides a canonical hook directory: **`hermes-agent/data/bin/entrypoint.d/`**. Drop an executable script in there (`01-name.sh`, `05-other.sh`, …) and `seed-entrypoint.sh` runs it as root on every container start, in lexicographic order, before the privilege drop.

Examples that belong here:

```sh
hermes-agent/data/bin/entrypoint.d/
  01-openai-sdk-patch.sh       # idempotent sed to tolerate `output is None`
  05-webhook-insecure-patch.sh # INSECURE_NO_AUTH safety-rail bypass for DTU tests
  10-gbrain-symlinks.sh        # /usr/local/bin/{bun,gbrain} re-link
```

Hooks must be idempotent (the entrypoint runs them at every boot) and silent on the happy path. A hook that exits non-zero aborts boot — don't swallow real errors with `|| true`.

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

The derived Dockerfile installs `jq` into the image layer. The hostex history-ingest scripts (`ingest-lib.sh`) call `jq` heavily, and the v2 run lost it on every `docker compose down/up` because the operator had been installing it at runtime via `docker exec -u 0:0 apt-get`. Baking it into the image makes it survive container recreates.

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
