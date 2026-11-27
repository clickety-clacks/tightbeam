"""Shared-message command adapter for Harklight Agent."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import sys

from agent_cli import AgentCLI


def report_retention_gap() -> None:
    print("Harklight people relay: sender feed position expired; rebuilding the pending baseline. "
          "Earlier historical events may be unavailable.", file=sys.stderr)


class HarklightAgent:
    def __init__(self, cli: AgentCLI, sender: str, state):
        self.cli = cli
        self.sender = sender
        self.session = state.session_id()
        self.journal = cli.one("journal-id")["journal_id"]
        state.pin_agent_journal(self.journal)
        capabilities = cli.one("capabilities")
        self.server_id = capabilities["server_id"]
        state.pin_server(self.server_id)
        self.shared = capabilities.get("shared_messages", False)

    def refusal(self, code: str, message: str) -> dict:
        return {"refusal": {"code": code, "message": message}}

    def write(self, operation_id: str, request: dict) -> dict:
        kind = request["kind"]
        if request.get("server_id", self.server_id) != self.server_id:
            raise ValueError("conversation belongs to a different Harklight Server")
        with tempfile.TemporaryDirectory(prefix="people-relay-") as temporary:
            payload = Path(temporary) / "payload.json"
            if kind == "send":
                args = self.send_args(request, payload)
            else:
                args = self.conversation_args(request, payload)
            result = self.cli.mutation(self.journal, operation_id, args, prepare=kind == "send")

        if result["kind"] == "refused":
            code = result.get("error") or "service_refused"
            refusal = self.refusal(code, f"Harklight refused the operation ({code}).")
            if code in {"no_recipients", "decider_unreachable"} and "recipients" in result:
                refusal["recipients"] = result["recipients"]
            return refusal
        if kind not in {"send", "update"}:
            return {}
        response = result["response"]
        revision = response["message"]["revision"]
        if type(revision) is not int or revision < 1:
            raise ValueError("Harklight returned an invalid request revision")
        if kind == "update":
            return {"remote_revision": revision}
        item_id = response["message"]["shared"]["shared_id"]
        if result["item_id"] != item_id:
            raise RuntimeError("Harklight returned inconsistent conversation IDs")
        return {
            "item_id": item_id,
            "server_id": self.server_id,
            "remote_revision": revision,
            "recipients": response["recipients"],
        }

    def send_args(self, request: dict, payload: Path) -> list[str]:
        policy = request["answer_policy"]
        args = ["send", "--session", self.session, "--sender-id", self.sender,
                "--type", "request" if policy else "fyi",
                f'--title={request["title"]}', f'--body={request["body"]}']
        for person in request["selector"]["people"]:
            args.extend(("--person-id", person))
        if request.get("organization"):
            args.extend(("--organization", request["organization"]))
        if policy and policy["kind"] == "named":
            args.extend(("--decider-id", policy["people"][0]))
        if policy and request["choices"]:
            payload.write_text(json.dumps(request["choices"]), encoding="utf-8")
            args.extend(("--choices-json", str(payload)))
        elif policy:
            args.append("--reply")
        return args

    def read_message(self, item_id: str) -> dict:
        return self.cli.one("message-get", "--shared", "--item-id", item_id)["message"]

    def conversation_args(self, request: dict, payload: Path) -> list[str]:
        item = ["--item-id", request["item_id"]]
        kind = request["kind"]
        if kind == "reply":
            args = ["reply", "--shared", *item, f'--body={request["body"]}']
            if "notify_person_id" in request:
                args.extend(("--notify-person-id", request["notify_person_id"]))
            return args
        if kind == "update":
            payload.write_text(json.dumps(request["message"]), encoding="utf-8")
            return ["revise", "--shared", *item, "--base-revision",
                    str(request["base_revision"]), "--message-json", str(payload)]
        if kind == "withdraw":
            return ["retract", "--shared", *item]
        if kind == "close":
            return ["chat-close", *item]
        raise ValueError("unknown outgoing people-message kind")

    def receipt(self, operation_id: str, event: dict) -> None:
        args = ["receipt", "--item-id", event["remote_conversation_id"]]
        if event["kind"] == "answer":
            args.extend(("--answer-id", event["event_id"]))
        else:
            args.extend(("--shared", "--entry-id", event["event_id"]))
        result = self.cli.mutation(self.journal, operation_id, args)
        if result["kind"] != "committed":
            print("Harklight refused a receipt for an accepted event", file=sys.stderr)

    def follow_args(self, checkpoint: dict) -> list[str]:
        return [
            *self.cli.argv, "listen", "--follow", "--shared", "--session", self.session, "--ack2",
            "--after", str(checkpoint["rev"]), "--continuation", checkpoint["continuation"],
            "--on-expired", "exit",
        ]

    def changes(self, checkpoint: dict | None):
        if not self.shared:
            return
        args = ["read", "--shared", "--session", self.session, "--ack2"]
        if checkpoint is None:
            start = self.cli.one(*args, "--pending", "--prepare")
            if start.get("kind") != "baseline_prepared" or start.get("shared_events") is not True:
                raise RuntimeError("Harklight did not prepare a shared baseline")
            checkpoint = {"rev": start["rev"], "continuation": start["continuation"],
                          "token": start["token"]}
            yield self.server_id, None, checkpoint

        baseline = "token" in checkpoint
        if baseline:
            status, rows = self.cli.run(*args, "--pending", "--resume", checkpoint["token"])
        else:
            status, rows = self.cli.run(
                *args, "--after", str(checkpoint["rev"]),
                "--continuation", checkpoint["continuation"],
            )
        if status == 2 and any(
            row.get("kind") in {"cursor_expired", "token_invalid"} for row in rows
        ):
            report_retention_gap()
            yield self.server_id, None, None
            return
        if status:
            raise RuntimeError(f"Harklight shared feed read exited {status}")
        complete = "baseline_complete" if baseline else "caught_up"
        if not rows or rows[-1].get("kind") != complete:
            raise RuntimeError("Harklight shared feed ended without a checkpoint")

        for row in rows:
            kind = row["kind"]
            if kind == complete:
                yield self.server_id, None, {
                    "rev": row["rev"], "continuation": checkpoint["continuation"],
                }
            elif "data" in row and "rev" in row:
                position = (
                    checkpoint if baseline else
                    {"rev": row["rev"], "continuation": checkpoint["continuation"]}
                )
                yield self.server_id, row, position
