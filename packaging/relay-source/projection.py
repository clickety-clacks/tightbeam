"""Translate shared Harklight records into neutral Tightbeam deliveries."""

from __future__ import annotations

from addresses import Addresses


def event_for(server_id: str, change: dict, addresses: Addresses) -> dict | None:
    kind = change["kind"]
    data = change["data"]
    speaker = data.get("speaker")
    if kind == "entry" and data.get("shared_entry_id") and data["author"] == "person":
        kind = "chat"
        event_id = data["shared_entry_id"]
        revision = data["request_revision"]
        content = {"body": data["text"]}
    elif kind == "answer":
        event_id = data["answer_id"]
        revision = data["request_revision"]
        terminal = data["terminal"]
        speaker = terminal["speaker"]
        content = {"answer": terminal["answer"]}
    elif kind == "seen":
        event_id = data["event_id"]
        revision = data["request_revision"]
        content = {"at_ms": data["at_ms"]}
    elif kind == "advisory":
        advisory = data["advisory"]
        kind = {
            "unseen_interval_elapsed": "reminder_not_seen",
            "soft_bounce": "reminder_not_acted",
        }.get(advisory["advisory_type"])
        if kind is None:
            return None
        event_id = advisory["advisory_id"]
        revision = advisory["request_revision"]
        content = {
            "body": advisory["text"],
            "people": [addresses.speaker(server_id, person)
                       for person in advisory.get("people", [])],
        }
    elif kind == "message" and data.get("shared", {}).get("chat_open") is False:
        kind = "closed"
        event_id = "chat-closed"
        revision = data["revision"]
        content = {}
    else:
        return None

    return {
        "server_id": server_id,
        "remote_conversation_id": data["item_id"],
        "event_id": event_id,
        "kind": kind,
        "remote_revision": revision,
        "speaker": addresses.speaker(server_id, speaker),
        "content": content,
    }
