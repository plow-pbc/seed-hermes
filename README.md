# seed-hermes

## Purpose

`seed-hermes` is the gateway-agnostic Docker seed for running Hermes Agent locally. It gives a coding agent enough structure to create a `hermes-agent/` workspace, authenticate ChatGPT through Hermes' `openai-codex` OAuth flow, and start Hermes entirely in Docker with host-visible files under `./data`.

Natural file-creation requests land in `hermes-agent/data/workspace/` on the host. The container's process working directory and Hermes `terminal.cwd` are both `/opt/data/workspace`, so relative file writes and the agent's environment hint point at the same host-visible workspace.

`./scripts/prepare.sh` writes a per-checkout `COMPOSE_PROJECT_NAME` and `HERMES_CONTAINER_NAME` into `hermes-agent/.env`. That prevents a second local seed checkout from recreating or stopping another checkout's Hermes container. The default ports are still `8642` and `9119`, so parallel instances must also set distinct `HERMES_API_PORT` and `HERMES_DASHBOARD_PORT` values before starting Docker.

The seed is intentionally generic: platform-specific behavior lives in optional gateway seeds. This repo ships no gateway install scripts; gateway seeds own their own plugin files, host orchestration, and verification.

The Hermes dashboard is enabled by default at `http://localhost:9119`. It shows the local Hermes web UI for sessions, logs, configuration, plugins, and dashboard-backed tools. Inside Docker, the entrypoint binds it to `0.0.0.0` and passes the dashboard's `--insecure` flag; this is acceptable for the disposable local container because the published port is intended for loopback browsing. Do not expose `9119` beyond the trusted local machine.

The Docker compose defaults keep Hermes autonomous inside the disposable container: `HERMES_YOLO_MODE=1` lets the agent act without interactive approval prompts, and `GATEWAY_ALLOW_ALL_USERS=true` lets the gateway accept inbound platform users. Platform-specific seeds are responsible for their own access gates.

The OpenAI-compatible API server on `8642` is not enabled by default. It is only needed for external OpenAI-compatible clients such as Open WebUI or LibreChat, and should be configured with an API key when used.
