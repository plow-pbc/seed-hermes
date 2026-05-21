# seed-hermes

## Purpose

`seed-hermes` is the gateway-agnostic Docker seed for running Hermes Agent locally. It gives a coding agent enough structure to create a `hermes-agent/` workspace, authenticate ChatGPT through Hermes' `openai-codex` OAuth flow, optionally fetch a platform gateway plugin, and start Hermes entirely in Docker with host-visible files under `./data`.

The seed is intentionally generic: platform-specific behavior lives in optional gateway seeds such as `seed-hermes-plow-chat`. The included Plow Chat fetch script is the deliberate seed-run shim that downloads that optional gateway's published file set when the user chooses it.

The Docker compose defaults keep Hermes autonomous inside the disposable container: `HERMES_YOLO_MODE=1` lets the agent act without interactive approval prompts, and `GATEWAY_ALLOW_ALL_USERS=true` lets the gateway accept inbound platform users. For Plow Chat, the access gate is the phone-verification flow: only verified chat members can participate, and the optional plugin's `PLOW_CHAT_AUTO_APPROVE_PAIRING` setting controls whether those verified Plow members are also approved through Hermes' generic pairing layer.
