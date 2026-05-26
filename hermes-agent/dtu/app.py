"""DTU — Data Test Unit.

Minimal in-process Flask mock of the hostex API surface that downstream
seeds (notably seed-hermes-airbnb-manager) drive during E2E validation.
Implements just enough of the hostex contract to exercise the
message_created webhook -> conversation fetch -> approve -> send-reply
round trip end to end.

State is in-memory. Restart the container to reset.

Endpoints:
    GET  /healthz                          -> {"status": "ok"}
    GET  /v3/properties                    -> properties fixture
    GET  /v3/conversations/<conv_id>       -> conversation detail
    POST /v3/conversations/<conv_id>       -> append host message
                                              (body: {"message": "..."})
    POST /v3/internal/guest-send           -> test harness: inject a guest
                                              message + fire message_created
                                              callback to DTU_WEBHOOK_URL
                                              (body: {"conversation_id":...,
                                               "content":...})

Drop-in replacement: if you have a richer DTU implementation elsewhere,
copy it over this file (keep the same Dockerfile / compose contract) and
rebuild the image. See dtu/README.md for the contract this stub commits to.
"""

from __future__ import annotations

import datetime as _dt
import os
import threading
import urllib.error
import urllib.request
import uuid

from flask import Flask, abort, jsonify, request

app = Flask(__name__)

_LOCK = threading.Lock()
_STATE: dict[str, dict] = {
    "properties": [
        {"id": "prop-mtn-home", "title": "Mtn Home"},
    ],
    "conversations": {},  # conversation_id -> conversation detail dict
}

WEBHOOK_URL = os.environ.get(
    "DTU_WEBHOOK_URL", "http://hermes:8787/webhooks/hostex-events"
)


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ensure_conversation(conversation_id: str) -> dict:
    """Look up or seed a conversation. Seeded conversations get a known guest
    so the message_created round-trip has somewhere to land."""
    with _LOCK:
        conv = _STATE["conversations"].get(conversation_id)
        if conv is not None:
            return conv
        conv = {
            "id": conversation_id,
            "guest": {"name": "CleanInstallTest"},
            "activities": [
                {
                    "property": {
                        "id": "prop-mtn-home",
                        "title": "Mtn Home",
                    }
                }
            ],
            "messages": [],
        }
        _STATE["conversations"][conversation_id] = conv
        return conv


def _fire_message_created(conversation_id: str, message_id: str) -> None:
    """POST a message_created callback at DTU_WEBHOOK_URL. Best-effort: log
    and swallow errors so the test harness sees a clean response even when
    Hermes isn't up yet."""
    payload = (
        f'{{"event":"message_created","conversation_id":"{conversation_id}",'
        f'"message_id":"{message_id}","timestamp":"{_now()}"}}'
    ).encode()
    req = urllib.request.Request(
        WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:  # noqa: S310
            app.logger.info(
                "dtu: webhook %s -> HTTP %s", WEBHOOK_URL, resp.status
            )
    except (urllib.error.URLError, TimeoutError) as exc:
        app.logger.warning("dtu: webhook %s failed: %s", WEBHOOK_URL, exc)


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok"})


@app.get("/v3/properties")
def list_properties():
    with _LOCK:
        return jsonify({"data": {"properties": list(_STATE["properties"])}})


@app.get("/v3/conversations/<conversation_id>")
def get_conversation(conversation_id: str):
    conv = _ensure_conversation(conversation_id)
    with _LOCK:
        return jsonify({"data": dict(conv)})


@app.post("/v3/conversations/<conversation_id>")
def post_message(conversation_id: str):
    body = request.get_json(silent=True) or {}
    text = body.get("message")
    if not isinstance(text, str) or not text:
        abort(400, description="missing 'message'")
    conv = _ensure_conversation(conversation_id)
    msg = {
        "id": f"msg-{uuid.uuid4().hex[:12]}",
        "sender_role": "host",
        "content": text,
        "created_at": _now(),
    }
    with _LOCK:
        conv["messages"].append(msg)
    return jsonify({"data": msg}), 200


@app.post("/v3/internal/guest-send")
def guest_send():
    """Test-only helper: inject a guest message and fire message_created."""
    body = request.get_json(silent=True) or {}
    conversation_id = body.get("conversation_id") or f"conv-{uuid.uuid4().hex[:12]}"
    content = body.get("content")
    if not isinstance(content, str) or not content:
        abort(400, description="missing 'content'")
    conv = _ensure_conversation(conversation_id)
    msg = {
        "id": f"msg-{uuid.uuid4().hex[:12]}",
        "sender_role": "guest",
        "content": content,
        "created_at": _now(),
    }
    with _LOCK:
        conv["messages"].append(msg)
    _fire_message_created(conversation_id, msg["id"])
    return jsonify(
        {"conversation_id": conversation_id, "message_id": msg["id"]}
    ), 200


if __name__ == "__main__":
    host = os.environ.get("DTU_HOST", "0.0.0.0")
    port = int(os.environ.get("DTU_PORT", "8080"))
    app.run(host=host, port=port)
