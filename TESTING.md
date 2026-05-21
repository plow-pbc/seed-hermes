# TESTING

Run date: 2026-05-21.

## Structural verification

From the repo root:

```sh
bash ../seed/ref/verify.sh .
```

Output:

```text
tree conforms
```

From `hermes-agent/`:

```sh
./scripts/prepare.sh
./scripts/verify.sh
```

Output:

```text
Prepared hermes-agent/.env, data/.env, data/workspace, and data/plugins.
seed-hermes scaffold verifies
```

## Docker-core scaffold

From `hermes-agent/`, with the tracked default `data/config.yaml` (`plugins.enabled: []`):

```sh
docker compose up -d
./scripts/check-ready.sh
docker compose logs --no-color --tail=100 hermes | grep -E 'No messaging platforms enabled|Gateway will continue running'
docker compose down
```

Observed:

```text
Hermes gateway readiness confirmed from data/logs/gateway.log.
hermes  | WARNING gateway.run: No messaging platforms enabled.
```

Port mappings were present while running:

```text
0.0.0.0:8642->8642/tcp
0.0.0.0:9119->9119/tcp
```

The official image returned an empty HTTP reply for `http://localhost:9119/` on this run, so `check-ready.sh` accepted the Hermes gateway-ready log line, which the design spec permits.

Workspace mount and UID/GID smoke:

```sh
docker compose exec -T -u "$(id -u):$(id -g)" hermes sh -lc 'echo container-write > /opt/data/workspace/hermes-write-smoke.txt'
printf 'host-edit\n' >> data/workspace/hermes-write-smoke.txt
ls -ln data/workspace/hermes-write-smoke.txt
sed -n '1,5p' data/workspace/hermes-write-smoke.txt
```

Observed:

```text
-rw-r--r-- 1 501 20 ... data/workspace/hermes-write-smoke.txt
container-write
host-edit
```

## ChatGPT OAuth

The auth script invokes the required non-TTY command:

```sh
docker compose run --rm -T hermes auth add openai-codex
```

I ran `./scripts/auth-openai-codex.sh` under a harness that terminated after the parser captured both required fields, without printing the short-lived code value into this file:

```text
captured device URL
captured device code format
oauth_capture url=True code=True completed=False
```

Browser approval and the first authenticated Hermes agent turn were not completed in this cook run because they require the user to approve the device flow in a browser. The script is ready to continue to completion when run interactively by the installing agent/user.

## Optional Plow Chat gateway fetch

From `hermes-agent/`:

```sh
./scripts/install-plow-chat-platform.sh
find data/plugins/plow-chat-platform -type f | sort
sed -n '1,12p' data/config.yaml
```

Observed fetched file set:

```text
data/plugins/plow-chat-platform/__init__.py
data/plugins/plow-chat-platform/plugin.yaml
data/plugins/plow-chat-platform/ref/hermes-plugin/plow_chat/__init__.py
data/plugins/plow-chat-platform/ref/hermes-plugin/plow_chat/adapter.py
data/plugins/plow-chat-platform/ref/hermes-plugin/plow_chat/plugin.yaml
```

Observed config enablement:

```yaml
plugins:
  enabled:
    - plow-chat-platform
```

With local dummy `PLOW_CHAT_*` values in ignored `data/.env`, `docker compose up` loaded the platform with no `ImportError`:

```text
INFO gateway.run: Connecting to plow_chat...
INFO gateway.run: ✓ plow_chat connected
INFO gateway.run: Gateway running with 1 platform(s)
```

The subsequent WebSocket connection warnings were expected because the smoke run used a dummy local base URL rather than a real Plow chat.

## Secret hygiene

Covered by `hermes-agent/scripts/verify.sh`:

- `hermes-agent/.env` is git-ignored.
- `hermes-agent/data/.env` is git-ignored.
- `hermes-agent/data/auth.json` is git-ignored.
- Tracked files are scanned for literal `ghp_`, model-key, Plow secret assignment, and OAuth credential patterns.
