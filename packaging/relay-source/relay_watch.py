"""Supervise readiness and sender-feed children with one durable state owner."""

from __future__ import annotations

import json
import selectors
import sqlite3
import subprocess
import sys
import time

from harklight_agent import report_retention_gap
from relay_process import RelayProcess
from tightbeam_people import TightbeamRefusal


OUTBOUND_BATCH = 8
RETRY_SECONDS = 15
WAIT_TIMEOUT_SECONDS = 30
RETRYABLE = (OSError, RuntimeError, ValueError, KeyError, TypeError, sqlite3.Error,
             subprocess.SubprocessError)


def readiness_failure(exit_status: int, stderr: str) -> str | None:
    if exit_status != 1:
        return None
    for line in stderr.splitlines():
        try:
            response = json.loads(line)
        except ValueError:
            continue
        if not isinstance(response, dict) or not isinstance(response.get("error"), dict):
            return None
        error = response["error"]
        status = response.get("httpStatus")
        if (status == 400 and error.get("code") == "invalid_message"
                and error.get("message") == "verb not allowed: people-wait"):
            return "unsupported"
        if status == 503 and error.get("code") == "people_readiness_unavailable":
            return "retry"
        return None
    if stderr.startswith("unknown command: people-wait — run 'tightbeam help' for usage. Commands:"):
        return "unsupported"
    return None


class RelayWatch:
    def __init__(self, relay):
        self.relay = relay
        self.selector = selectors.DefaultSelector()
        self.children = {}
        self.retry_at = {"readiness": 0.0, "listener": 0.0, "receipts": 0.0}
        self.wait_deadline = None
        self.wait_response = None
        self.wait_supported = True
        self.listener_continuation = None
        self.listener_started = False

    def log(self, action: str, error: Exception) -> None:
        print(f"Harklight people relay: {action}: {error}", file=sys.stderr)

    def close_child(self, role: str) -> None:
        child = self.children.pop(role, None)
        if child is not None:
            child.close()

    def delay(self, role: str) -> None:
        self.close_child(role)
        self.retry_at[role] = time.monotonic() + RETRY_SECONDS

    def outbound_batch(self) -> bool | None:
        try:
            return self.relay.outbound(limit=OUTBOUND_BATCH)
        except RETRYABLE as error:
            if isinstance(error, TightbeamRefusal) and (
                error.status in {401, 403}
                or error.error["code"] in {"people_messaging_not_enabled", "invalid"}
            ):
                raise
            self.log("outbound retry", error)
            self.delay("readiness")
            return None

    def start_readiness(self, *, drain: bool = True) -> None:
        if drain:
            ready = self.outbound_batch()
            if ready:
                # Give the listener and receipts a scheduling turn before
                # collecting another bounded batch.
                self.retry_at["readiness"] = 0.0
            if ready is not False:
                return
        if not self.wait_supported:
            self.delay("readiness")
            return
        self.wait_response = None
        self.children["readiness"] = RelayProcess(
            self.selector, self.relay.people.wait_args(), "readiness",
        )
        self.wait_deadline = time.monotonic() + WAIT_TIMEOUT_SECONDS

    def readiness(self, frames: list[dict], ended: bool) -> None:
        for frame in frames:
            if self.wait_response is not None or not isinstance(frame.get("records"), list):
                raise RuntimeError("Tightbeam people-wait returned an invalid response")
            self.wait_response = frame
        if not ended:
            return
        status, stderr = self.children["readiness"].result()
        self.close_child("readiness")
        failure = readiness_failure(status, stderr)
        if failure == "unsupported":
            self.wait_supported = False
            print("Harklight people relay: people-wait unavailable, using bounded collect",
                  file=sys.stderr)
        if failure is not None:
            self.delay("readiness")
            return
        if status or self.wait_response is None:
            raise RuntimeError(f"Tightbeam people-wait failed (exit {status}): {stderr.strip()}")
        # Empty is a clean bounded idle return. The next wait registers before
        # reading again, so there is no gap during the handoff between waits.
        self.start_readiness(drain=bool(self.wait_response["records"]))

    def start_listener(self) -> None:
        if self.listener_started:
            self.outbound_batch()
        self.listener_started = True
        try:
            self.relay.inbound()
            checkpoint = self.relay.state.checkpoint()
            if checkpoint is None or "token" in checkpoint:
                raise RuntimeError("Harklight shared feed has no completed baseline")
            self.listener_continuation = checkpoint["continuation"]
            self.children["listener"] = RelayProcess(
                self.selector, self.relay.agent.follow_args(checkpoint), "listener",
            )
        except RETRYABLE as error:
            self.log("sender catch-up retry", error)
            self.delay("listener")

    def listener(self, frames: list[dict], ended: bool) -> None:
        for frame in frames:
            kind = frame["kind"]
            if kind == "cursor_expired":
                self.close_child("listener")
                report_retention_gap()
                self.relay.state.advance(None)
                self.retry_at["listener"] = 0.0
                return
            if kind == "focus":
                continue
            revision = frame["rev"]
            if type(revision) is not int or revision < self.relay.state.checkpoint()["rev"]:
                raise ValueError("Harklight sender feed revision moved backwards")
            checkpoint = {"rev": revision, "continuation": self.listener_continuation}
            change = None if kind == "caught_up" else frame
            if change is not None and not isinstance(change.get("data"), dict):
                raise ValueError("Harklight sender feed change lacks data")
            if not self.relay.apply_change(self.relay.agent.server_id, change, checkpoint):
                raise RuntimeError("Harklight sender event is awaiting its send report or revision")
        if ended:
            self.delay("listener")

    def receipts(self) -> None:
        try:
            self.relay.receipts()
        except RETRYABLE as error:
            self.log("receipt retry", error)
        self.retry_at["receipts"] = time.monotonic() + RETRY_SECONDS

    def tick(self) -> None:
        now = time.monotonic()
        if "readiness" in self.children and now >= self.wait_deadline:
            self.delay("readiness")
        if "readiness" not in self.children and now >= self.retry_at["readiness"]:
            self.start_readiness()
        if "listener" not in self.children and now >= self.retry_at["listener"]:
            self.start_listener()
        if now >= self.retry_at["receipts"]:
            self.receipts()
        deadlines = [self.retry_at[role] for role in self.retry_at if role not in self.children]
        if "readiness" in self.children:
            deadlines.append(self.wait_deadline)
        timeout = max(0.0, min(deadlines) - time.monotonic())
        for key, _events in self.selector.select(timeout):
            role = key.data
            child = self.children[role]
            if role == "readiness":
                self.readiness(*child.frames())
            else:
                try:
                    self.listener(*child.frames())
                except RETRYABLE as error:
                    self.log("sender listen retry", error)
                    self.delay("listener")
                if self.relay.state.receipts():
                    self.receipts()

    def run(self) -> None:
        try:
            while True:
                self.tick()
        finally:
            for role in list(self.children):
                self.close_child(role)
            self.selector.close()
