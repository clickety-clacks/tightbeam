"""Durable relay writes and feed checkpoint."""

from __future__ import annotations

import json
import sqlite3
import uuid
from pathlib import Path
from typing import Callable


class RelayState:
    def __init__(self, path: Path, connection: str, sender: str):
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        try:
            with self.db:
                self.db.execute("""
                    CREATE TABLE IF NOT EXISTS feed (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        connection TEXT NOT NULL,
                        sender TEXT NOT NULL,
                        checkpoint TEXT,
                        session_id TEXT NOT NULL,
                        agent_journal_id TEXT,
                        server_id TEXT
                    )
                """)
                self.db.execute("""
                    CREATE TABLE IF NOT EXISTS writes (
                        record_id TEXT PRIMARY KEY,
                        operation_id TEXT NOT NULL,
                        request TEXT NOT NULL,
                        result TEXT,
                        reported INTEGER NOT NULL DEFAULT 0
                    )
                """)
                self.db.execute("""
                    CREATE TABLE IF NOT EXISTS conversations (
                        record_id TEXT PRIMARY KEY,
                        server_id TEXT NOT NULL,
                        item_id TEXT NOT NULL,
                        UNIQUE(server_id, item_id)
                    )
                """)
                self.db.execute("""
                    CREATE TABLE IF NOT EXISTS receipts (
                        event_key TEXT PRIMARY KEY,
                        operation_id TEXT NOT NULL,
                        event TEXT NOT NULL
                    )
                """)
                self.db.execute("""
                    CREATE TABLE IF NOT EXISTS events (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        event TEXT NOT NULL
                    )
                """)
                self.db.execute("""
                    CREATE TABLE IF NOT EXISTS refused_events (
                        event_key TEXT PRIMARY KEY,
                        event TEXT NOT NULL,
                        checkpoint TEXT NOT NULL,
                        status INTEGER NOT NULL,
                        error TEXT NOT NULL,
                        later_bound_revision INTEGER NOT NULL
                    )
                """)
                self.db.execute(
                    "INSERT OR IGNORE INTO feed (singleton, connection, sender, session_id) VALUES (1, ?, ?, ?)",
                    (connection, sender, str(uuid.uuid4())),
                )
                scope = self.db.execute("SELECT connection, sender FROM feed").fetchone()
                if tuple(scope) != (connection, sender):
                    raise ValueError("relay state belongs to a different connection or sender")
        except Exception:
            self.db.close()
            raise

    def close(self) -> None:
        self.db.close()

    def prepare(self, record_id: str, request: Callable[[], dict]) -> sqlite3.Row:
        # Only a new record consults the current address mapping.
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            row = self.db.execute(
                "SELECT * FROM writes WHERE record_id = ?", (record_id,)
            ).fetchone()
            if row is None:
                self.db.execute(
                    "INSERT INTO writes (record_id, operation_id, request) VALUES (?, ?, ?)",
                    (record_id, str(uuid.uuid4()), json.dumps(request())),
                )
                row = self.db.execute(
                    "SELECT * FROM writes WHERE record_id = ?", (record_id,)
                ).fetchone()
        return row

    def save_result(self, record_id: str, result: dict) -> None:
        # Persist a known outcome before reporting it to Tightbeam. A lost
        # Tightbeam acknowledgment only requires replaying that report.
        with self.db:
            self.db.execute(
                "UPDATE writes SET result = ? WHERE record_id = ? AND result IS NULL",
                (json.dumps(result), record_id),
            )
            if "remote_conversation_id" in result:
                self.db.execute(
                    "INSERT INTO conversations VALUES (?, ?, ?)",
                    (record_id, result["server_id"], result["remote_conversation_id"]),
                )

    def binding(self, conversation_id: str) -> dict | None:
        row = self.db.execute(
            "SELECT server_id, item_id FROM conversations WHERE record_id = ?",
            (conversation_id,),
        ).fetchone()
        return None if row is None else dict(row)

    def owns(self, server_id: str, item_id: str) -> bool:
        row = self.db.execute(
            "SELECT 1 FROM conversations WHERE server_id = ? AND item_id = ?",
            (server_id, item_id),
        ).fetchone()
        return row is not None

    def unreported(self, limit: int | None = None) -> list[dict]:
        rows = self.db.execute(
            "SELECT result FROM writes WHERE result IS NOT NULL AND reported = 0 ORDER BY rowid LIMIT ?",
            (-1 if limit is None else limit,),
        )
        return [json.loads(row[0]) for row in rows]

    def mark_reported(self, record_id: str) -> None:
        with self.db:
            self.db.execute("UPDATE writes SET reported = 1 WHERE record_id = ?", (record_id,))

    def checkpoint(self):
        encoded = self.db.execute("SELECT checkpoint FROM feed").fetchone()[0]
        return None if encoded is None else json.loads(encoded)

    def advance(self, checkpoint) -> None:
        with self.db:
            self.db.execute("UPDATE feed SET checkpoint = ?", (json.dumps(checkpoint),))

    def session_id(self) -> str:
        return self.db.execute("SELECT session_id FROM feed").fetchone()[0]

    def pending_event(self) -> dict | None:
        row = self.db.execute("SELECT event FROM events").fetchone()
        return None if row is None else json.loads(row[0])

    def prepare_event(self, event: dict) -> None:
        with self.db:
            self.db.execute("INSERT INTO events VALUES (1, ?)", (json.dumps(event),))

    def complete_event(self, checkpoint, receipt: dict | None = None) -> None:
        with self.db:
            if receipt is not None:
                event = receipt["event"]
                key = self.event_key(event)
                if receipt.get("groups"):
                    event = {**event, "groups": True}
                self.db.execute(
                    "INSERT OR IGNORE INTO receipts VALUES (?, ?, ?)",
                    (key, receipt["receipt_id"], json.dumps(event)),
                )
            self.db.execute("DELETE FROM events WHERE singleton = 1")
            self.db.execute("UPDATE feed SET checkpoint = ?", (json.dumps(checkpoint),))

    def pin_agent_journal(self, journal_id: str) -> None:
        with self.db:
            self.db.execute(
                "UPDATE feed SET agent_journal_id = ? WHERE agent_journal_id IS NULL",
                (journal_id,),
            )
            pinned = self.db.execute("SELECT agent_journal_id FROM feed").fetchone()[0]
            if pinned != journal_id:
                raise ValueError("the Harklight Agent journal changed; restore the original journal")

    def pin_server(self, server_id: str) -> None:
        with self.db:
            self.db.execute("UPDATE feed SET server_id = ? WHERE server_id IS NULL", (server_id,))
            pinned = self.db.execute("SELECT server_id FROM feed").fetchone()[0]
            if pinned != server_id:
                raise ValueError("the enrolled Harklight Server changed")

    def remember_binding(self, record: dict) -> None:
        binding = {"server_id": record["server_id"], "item_id": record["remote_conversation_id"]}
        conversation_id = record["conversation_id"]
        with self.db:
            self.db.execute(
                "INSERT OR IGNORE INTO conversations VALUES (?, ?, ?)",
                (conversation_id, binding["server_id"], binding["item_id"]),
            )
            if self.binding(conversation_id) != binding:
                raise ValueError("Tightbeam reported a different binding for this conversation")

    def receipts(self) -> list[sqlite3.Row]:
        return list(self.db.execute("SELECT * FROM receipts"))

    def complete_receipt(self, event_key: str) -> None:
        with self.db:
            self.db.execute("DELETE FROM receipts WHERE event_key = ?", (event_key,))

    def binding_unreported(self, server_id: str, item_id: str) -> bool:
        return self.db.execute(
            """SELECT 1 FROM conversations c JOIN writes w ON c.record_id = w.record_id
               WHERE c.server_id = ? AND c.item_id = ? AND w.reported = 0""",
            (server_id, item_id),
        ).fetchone() is not None

    def has_unresolved_send(self) -> bool:
        return self.db.execute(
            "SELECT 1 FROM writes WHERE result IS NULL AND json_extract(request, '$.kind') = 'send' LIMIT 1"
        ).fetchone() is not None

    @staticmethod
    def event_key(event: dict) -> str:
        return json.dumps([event[field] for field in (
            "server_id", "remote_conversation_id", "kind", "event_id"
        )])

    def was_refused(self, event: dict) -> bool:
        return self.db.execute(
            "SELECT 1 FROM refused_events WHERE event_key = ?", (self.event_key(event),)
        ).fetchone() is not None

    def refuse_event(self, pending: dict, status: int, error: dict, later_revision: int) -> None:
        event = pending["event"]
        checkpoint = json.dumps(pending["checkpoint"])
        with self.db:
            self.db.execute(
                "INSERT OR IGNORE INTO refused_events VALUES (?, ?, ?, ?, ?, ?)",
                (self.event_key(event), json.dumps(event), checkpoint, status,
                 json.dumps(error), later_revision),
            )
            self.db.execute("DELETE FROM events WHERE singleton = 1")
            self.db.execute("UPDATE feed SET checkpoint = ?", (checkpoint,))
