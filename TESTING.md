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

`prepare.sh` also writes checkout-specific `COMPOSE_PROJECT_NAME` and `HERMES_CONTAINER_NAME` values into ignored `.env`. This prevents `docker compose up/down` in one clone from targeting a different clone's container. Parallel test runs still need distinct host ports.

## Docker-core scaffold

From `hermes-agent/`, with the tracked default `data/config.yaml` (`plugins.enabled: []`), use non-default ports when another Hermes instance is already using `8642`/`9119`:

```sh
./scripts/prepare.sh
# For parallel runs, set HERMES_API_PORT and HERMES_DASHBOARD_PORT in .env before starting.
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

### Dashboard default

Fresh isolated dashboard test:

```sh
cat > .env <<EOF
COMPOSE_PROJECT_NAME=hermes-dashboard-test
HERMES_CONTAINER_NAME=hermes-dashboard-test
HERMES_UID=$(id -u)
HERMES_GID=$(id -g)
HERMES_API_PORT=28642
HERMES_DASHBOARD_PORT=29119
EOF
docker compose --project-name hermes-dashboard-test up -d
./scripts/check-ready.sh
curl -sS -o /tmp/hermes-dashboard.html -w '%{http_code}' http://localhost:29119/
curl -sS -o /tmp/hermes-api-health.out -w '%{http_code}' http://localhost:28642/health
```

Observed:

```text
Hermes dashboard is reachable on http://localhost:29119/
dashboard_http_code=200
dashboard_title=Hermes Agent - Dashboard
dashboard_contains_hermes=yes
api_health_code=000
Starting hermes dashboard on 0.0.0.0:9119 (background)
[dashboard]   Hermes Web UI -> http://0.0.0.0:9119
```

The `api_health_code=000` result was an empty reply, confirming the published `8642` port is not serving the OpenAI-compatible API server by default.

### File-write cwd regression

Root cause investigated in the Hermes reference source:

- `gateway/run.py` bridges `config.yaml` `terminal.cwd` into `TERMINAL_CWD`.
- `tools/file_tools.py` resolves relative file paths against `TERMINAL_CWD`.
- `agent/prompt_builder.py` reports `Current working directory: {os.getcwd()}` for the local backend.
- The image Dockerfile sets `WORKDIR /opt/hermes`, so the agent was being told `/opt/hermes` even though relative file tools were configured for `/opt/data/workspace`.

Fresh isolated test instance:

```sh
cat > .env <<EOF
COMPOSE_PROJECT_NAME=hermes-fix-write
HERMES_CONTAINER_NAME=hermes-fix-write
HERMES_UID=$(id -u)
HERMES_GID=$(id -g)
HERMES_API_PORT=18642
HERMES_DASHBOARD_PORT=19119
EOF
docker compose --project-name hermes-fix-write up -d
./scripts/check-ready.sh
docker compose --project-name hermes-fix-write exec -T hermes sh -lc 'pwd; /opt/hermes/.venv/bin/python - <<PY
from agent.prompt_builder import build_environment_hints
print(build_environment_hints())
PY'
```

Observed:

```text
Hermes gateway readiness confirmed from data/logs/gateway.log.
name=/hermes-fix-write workdir=/opt/data/workspace project=hermes-fix-write
exec_pwd=/opt/data/workspace
Current working directory: /opt/data/workspace
```

With a restored testing-only `data/auth.json`, an isolated `hermes chat -q` request to create `HELLO_WORLD_CWD_TEST.txt` produced:

```text
workspace_file=yes
data_root_file=no
workspace_content=HELLO WORLD
permission_denied_count=0
mutation_warning_count=0
opt_hermes_attempt_count=0
/opt/data/workspace/HELLO_WORLD_CWD_TEST.txt
```

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

## Secret hygiene

Covered by `hermes-agent/scripts/verify.sh`:

- `hermes-agent/.env` is git-ignored.
- `hermes-agent/data/.env` is git-ignored.
- `hermes-agent/data/auth.json` is git-ignored.
- Tracked files are scanned for GitHub PAT prefixes, model-key, platform secret assignment, and OAuth credential patterns.
