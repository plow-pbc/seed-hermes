# seed-hermes

## Purpose

`seed-hermes` is the gateway-agnostic Docker seed for running Hermes Agent locally. It gives a coding agent enough structure to create a `hermes-agent/` workspace, authenticate ChatGPT through Hermes' `openai-codex` OAuth flow, optionally fetch a platform gateway plugin, and start Hermes entirely in Docker with host-visible files under `./data`.

The seed is intentionally generic: platform-specific setup lives in optional gateway seeds such as `seed-hermes-plow-chat`.
