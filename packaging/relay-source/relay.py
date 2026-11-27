"""Move durable people messages between Tightbeam and Harklight Agent."""

from __future__ import annotations

import argparse
import fcntl
import json
from pathlib import Path
import sqlite3
import signal
import subprocess
import sys
import uuid

from addresses import Addresses
from agent_cli import AgentCLI
from harklight_agent import HarklightAgent
from outgoing import delivery_outcomes, is_group_address, prepare_send
from projection import event_for
from relay_state import RelayState
from relay_watch import RelayWatch
from tightbeam_people import TightbeamPeople, TightbeamRefusal


class Relay:
    def __init__(self, state: RelayState, addresses: Addresses, people: TightbeamPeople, agent):
        self.state = state
        self.addresses = addresses
        self.people = people
        self.agent = agent

    def prepare(self, record: dict) -> dict:
        kind = record["kind"]
        if kind == "send":
            return {"kind": kind, **prepare_send(record, self.addresses)}
        binding = self.state.binding(record["conversation_id"])
        if binding is None:
            return {"refusal": {"code": "conversation_undelivered",
                                "message": "The initial send did not open a conversation."}}
        request = {"kind": kind, **binding, "body": record["body"]}
        if any(is_group_address(address) for address in record["addresses"]):
            request["groups"] = True
        if kind == "update":
            if request.get("groups"):
                current = self.agent.read_message(binding["item_id"], groups=True)
            else:
                current = self.agent.read_message(binding["item_id"])
            request["base_revision"] = current["revision"]
            message = {**current["message"], "title": record["title"], "body": record["body"]}
            if record["answer_rule"] and record["choices"] is not None:
                actions = [
                    {"id": choice["id"], "label": choice["label"],
                     "kind": "value", "value": choice["id"]}
                    for choice in record["choices"]
                ]
                message["answer_ui"] = {
                    "schema": "attention-client.actions/1",
                    "actions": actions or [{"id": "reply", "label": "Reply", "kind": "text"}],
                }
            request["message"] = message
        if kind == "close" and request["body"]:
            request["closing_reply_id"] = str(uuid.uuid4())
        if kind == "reply" and record.get("address"):
            person = self.addresses.users.get(record["address"].removeprefix("user:"))
            if person is None:
                return {"refusal": {"code": "mention_unreachable",
                                    "message": "The mention has no Harklight person mapping."}}
            request["notify_person_id"] = person
        return request

    def deliver(self, row) -> dict:
        request = json.loads(row["request"])
        report = {"id": row["record_id"], "outcomes": []}
        if "refusal" in request:
            return {**report, "refusal": request["refusal"]}
        kind = request["kind"]
        if kind == "send" and request["selector"] == {"kind": "people", "people": []}:
            return {**report, "outcomes": request["missing"],
                    "refusal": {"code": "no_recipients", "message": "No recipients are mapped."}}

        operation_id = row["operation_id"]
        if kind == "close" and request["body"]:
            reply = {**request, "kind": "reply"}
            response = self.agent.write(request["closing_reply_id"], reply)
            if "refusal" in response:
                return {**report, "refusal": response["refusal"]}

        response = self.agent.write(operation_id, request)
        if "refusal" in response:
            report["refusal"] = response["refusal"]
        if "remote_revision" in response:
            report["remote_revision"] = response["remote_revision"]
        if kind == "send" and "recipients" in response:
            delivered = "item_id" in response
            report["outcomes"] = delivery_outcomes(request, response["recipients"], delivered)
            if delivered:
                report.update(server_id=response["server_id"],
                              remote_conversation_id=response["item_id"])
        return report

    def report(self, result: dict) -> None:
        self.people.report(result)
        self.state.mark_reported(result["id"])

    def deliver_record(self, record: dict) -> None:
        if record.get("remote_conversation_id"):
            self.state.remember_binding(record)
        row = self.state.prepare(record["id"], lambda: self.prepare(record))
        if row["result"] is None:
            result = self.deliver(row)
            self.state.save_result(record["id"], result)
        else:
            result = json.loads(row["result"])
        self.report(result)

    def outbound(self, limit: int | None = None) -> bool:
        attempted = set()
        errors = []
        for result in self.state.unreported(limit):
            attempted.add(result["id"])
            try:
                self.report(result)
            except (KeyError, TypeError, OSError, ValueError, RuntimeError,
                    subprocess.SubprocessError) as error:
                errors.append(error)
        remaining = None if limit is None else limit - len(attempted)
        if remaining is None:
            records = self.people.collect()
        elif remaining > 0:
            records = self.people.collect(limit=remaining)
        else:
            records = []
        for record in records:
            if record["id"] not in attempted:
                try:
                    self.deliver_record(record)
                except (KeyError, TypeError, OSError, ValueError, RuntimeError,
                        subprocess.SubprocessError) as error:
                    errors.append(error)
        if errors:
            raise errors[0]
        return bool(records) or remaining == 0

    def accept_pending(self) -> None:
        pending = self.state.pending_event()
        if pending is None:
            return
        event = pending["event"]
        if self.state.was_refused(event):
            self.state.complete_event(pending["checkpoint"])
            return
        try:
            self.people.event(event)
        except TightbeamRefusal as refusal:
            if refusal.error["code"] != "revision_unbound":
                raise
            binding = self.people.lookup(event["server_id"], event["remote_conversation_id"])
            bound = self.bound_revisions(binding)
            revision = event["remote_revision"]
            # R4 only admits strictly increasing revision bindings. A gap
            # behind an accepted report cannot be filled by a later report.
            if revision in bound or not any(later > revision for later in bound):
                raise
            self.state.refuse_event(pending, refusal.status, refusal.error, max(bound))
            print("Harklight people relay: retained a refused event for an unbindable revision",
                  file=sys.stderr)
            return
        receipt = pending if pending["receipt_id"] is not None else None
        self.state.complete_event(pending["checkpoint"], receipt)

    def receipts(self) -> None:
        failed = False
        for receipt in self.state.receipts():
            try:
                self.agent.receipt(receipt["operation_id"], json.loads(receipt["event"]))
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                failed = True
                continue
            self.state.complete_receipt(receipt["event_key"])
        if failed:
            raise RuntimeError("One or more Harklight receipts are pending retry")

    @staticmethod
    def bound_revisions(binding: dict | None) -> set[int]:
        if binding is None:
            return set()
        revisions = {entry["remote_revision"] for entry in binding["revisions"]}
        if any(type(revision) is not int or revision < 1 for revision in revisions):
            raise ValueError("Tightbeam returned invalid remote revision bindings")
        return revisions

    def apply_change(self, server_id: str, change: dict | None, checkpoint) -> bool:
        """Return false if the feed must hold this position for another attempt."""
        item_id = change.get("data", {}).get("item_id") if change is not None else None
        if item_id is not None and self.state.binding_unreported(server_id, item_id):
            return False
        event = event_for(server_id, change, self.addresses) if change is not None else None
        if event:
            binding = self.people.lookup(server_id, item_id)
            if binding is None and (
                self.state.owns(server_id, item_id) or self.state.has_unresolved_send()
            ):
                return False
            if binding is not None:
                bound = self.bound_revisions(binding)
                revision = event["remote_revision"]
                if revision not in bound and not any(later > revision for later in bound):
                    return False
                self.state.prepare_event({
                    "event": event,
                    "checkpoint": checkpoint,
                    "groups": bool((checkpoint or {}).get("groups")),
                    "receipt_id": (
                        str(uuid.uuid4()) if event["kind"] in {"chat", "answer"}
                        and change.get("pending") is not False else None
                    ),
                })
                self.accept_pending()
                return True
        self.state.advance(checkpoint)
        return True

    def inbound(self) -> None:
        self.accept_pending()
        held = set()
        for server_id, change, checkpoint in self.agent.changes(self.state.checkpoint()):
            item_id = change.get("data", {}).get("item_id") if change is not None else None
            if item_id is not None and item_id in held:
                continue
            if held:
                checkpoint = self.state.checkpoint()
            try:
                applied = self.apply_change(server_id, change, checkpoint)
            except (KeyError, TypeError, OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                if item_id is None or self.state.pending_event() is not None:
                    raise
                applied = False
            if not applied:
                held.add(item_id)
        if held:
            raise RuntimeError("One or more Harklight events are waiting for a valid payload or send report")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--watch", action="store_true", help="supervise the live relay")
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding="utf-8"))
        addresses = Addresses(config["users"])
        connection = str(Path(config["connection"]).expanduser().resolve())
        sender = config["sender"]
        if not isinstance(sender, str) or not sender.strip():
            raise ValueError("sender must be a nonempty Harklight sender ID")

        args.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (args.state_dir / "run.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                if args.watch:
                    raise RuntimeError("another relay already owns this state directory") from None
                return 0
            state = RelayState(args.state_dir / "relay.db", connection, sender)
            try:
                agent = HarklightAgent(AgentCLI(connection, args.state_dir / "agent"), sender, state)
                relay = Relay(state, addresses, TightbeamPeople(), agent)
                if args.watch:
                    def stop(_signal, _frame):
                        raise SystemExit(0)
                    signal.signal(signal.SIGTERM, stop)
                    RelayWatch(relay).run()
                    return 0
                failures = []
                for action in (relay.outbound, relay.inbound, relay.receipts):
                    try:
                        action()
                    except (KeyError, TypeError, OSError, ValueError, RuntimeError,
                            sqlite3.Error, subprocess.SubprocessError):
                        failures.append(action.__name__)
                if failures:
                    raise RuntimeError(f"Retry required for {', '.join(failures)}")
            finally:
                state.close()
    except (KeyError, OSError, ValueError, RuntimeError, sqlite3.Error,
            subprocess.SubprocessError) as error:
        print(f"Harklight people relay: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
