# DTU — Data Test Unit

Opt-in Flask service that mocks the hostex API surface for E2E testing of
seeds that target hostex (notably `seed-hermes-airbnb-manager`).

## Why it's here

The substrate clean-install run surfaced two related defects:

- **#11**: clean machines have no `dtu` CLI, no Flask, and can't `apt install
  python3-venv` as non-root.
- **#14**: when DTU runs in a separate host shell, `127.0.0.1:8080` (operator's
  view) and `host.docker.internal:8080` (Hermes container's view) resolve to
  different network namespaces in Docker-in-Docker substrates, so the boss
  fetches conversation detail from a different state namespace than `dtu guest
  send` writes to.

Running DTU as a compose service on the Hermes network fixes both: Hermes
reaches DTU at `http://dtu:8080` (Docker DNS), the host reaches it at
`http://localhost:${DTU_PORT:-8080}`, and both views are the same process /
same state.

## Run

```sh
./scripts/prepare.sh
docker compose -f compose.yaml -f compose.dtu.yaml up -d
```

From a Hermes container:

```sh
./scripts/hermes-exec.sh hermes -- curl -sS http://dtu:8080/healthz
```

From the host:

```sh
curl -sS http://localhost:8080/healthz
```

## Contract

Endpoints implemented by this stub:

| Method | Path                                | Behavior |
|---|---|---|
| GET    | `/healthz`                          | `{"status": "ok"}` |
| GET    | `/v3/properties`                    | properties fixture |
| GET    | `/v3/conversations/<conv_id>`       | conversation detail (auto-seeded on first read) |
| POST   | `/v3/conversations/<conv_id>`       | append host message (body: `{"message": "..."}`) |
| POST   | `/v3/internal/guest-send`           | test harness: inject guest message + fire `message_created` webhook to `DTU_WEBHOOK_URL` |

State is in-memory. Restart the container to reset.

## Swapping in a different DTU implementation

If you have a richer DTU app elsewhere (matching the same hostex API surface),
replace `dtu/app.py` with your implementation and rebuild:

```sh
docker compose -f compose.yaml -f compose.dtu.yaml build dtu
docker compose -f compose.yaml -f compose.dtu.yaml up -d dtu
```

The `Dockerfile` and `requirements.txt` keep DTU runnable on any host with
Docker — no host Flask, no `python3-venv`, no `pip --break-system-packages`.

## Environment

| Variable           | Default                                        | Purpose |
|---|---|---|
| `DTU_HOST`         | `0.0.0.0`                                      | Bind address inside the container. |
| `DTU_PORT`         | `8080`                                         | Port inside the container. Host mapping comes from `${DTU_PORT:-8080}` in `compose.dtu.yaml`. |
| `DTU_WEBHOOK_URL`  | `http://hermes:8787/webhooks/hostex-events`    | Where DTU posts `message_created` callbacks. Override if your Hermes webhook lives on a different route. |
