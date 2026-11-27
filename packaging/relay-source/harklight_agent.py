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
        self.state = state
        self.refresh_capabilities()

    def refresh_capabilities(self) -> None:
        capabilities = self.cli.one("capabilities")
        server_id = capabilities["server_id"]
        self.state.pin_server(server_id)
        self.server_id = server_id
        self.shared = capabilities.get("shared_messages", False)
        self.groups = self.shared and capabilities.get("groups", False) and self.cli.supports_groups()

    def group_send_available(self) -> bool:
        self.refresh_capabilities()
        return self.groups

    def refusal(self, code: str, message: str) -> dict:
        return {"refusal": {"code": code, "message": message}}

    def write(self, operation_id: str, request: dict) -> dict:
        kind = request["kind"]
        if request.get("server_id", self.server_id) != self.server_id:
            raise ValueError("conversation belongs to a different Harklight Server")
        group_send = kind == "send" and request["selector"]["kind"] == "group"
        with tempfile.TemporaryDirectory(prefix="people-relay-") as temporary:
            payload = Path(temporary) / "payload.json"
            if kind == "send":
                args = self.send_args(request, payload)
            else:
                args = self.conversation_args(request, payload)
            result = self.cli.mutation(
                self.journal, operation_id, args, prepare=kind == "send",
                available=self.group_send_available if group_send else None,
            )

        if result["kind"] == "refused":
            code = result.get("error") or "service_refused"
            status = result.get("status")
            detail = f"HTTP {status}, {code}" if type(status) is int else code
            refusal = self.refusal(code, f"Harklight refused the operation ({detail}).")
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
        selector = request["selector"]
        if selector["kind"] == "group":
            args.append(f'--group-id={selector["group_id"]}' if "group_id" in selector
                        else f'--group-name={selector["name"]}')
        else:
            for person in selector["people"]:
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

    def read_message(self, item_id: str, *, groups: bool = False) -> dict:
        scope = "--groups" if groups else "--shared"
        return self.cli.one("message-get", scope, "--item-id", item_id)["message"]

    def conversation_args(self, request: dict, payload: Path) -> list[str]:
        item = ["--item-id", request["item_id"]]
        groups = request.get("groups", False)
        scope = "--groups" if groups else "--shared"
        kind = request["kind"]
        if kind == "reply":
            args = ["reply", scope, *item, f'--body={request["body"]}']
            if "notify_person_id" in request:
                args.extend(("--notify-person-id", request["notify_person_id"]))
            return args
        if kind == "update":
            payload.write_text(json.dumps(request["message"]), encoding="utf-8")
            return ["revise", scope, *item, "--base-revision",
                    str(request["base_revision"]), "--message-json", str(payload)]
        if kind == "withdraw":
            return ["retract", scope, *item]
        if kind == "close":
            return ["chat-close", *(["--groups"] if groups else []), *item]
        raise ValueError("unknown outgoing people-message kind")

    def receipt(self, operation_id: str, event: dict) -> None:
        groups = event.get("groups", False)
        if groups and not self.groups:
            raise RuntimeError("Harklight group receipt is waiting for group capability")
        args = ["receipt", "--item-id", event["remote_conversation_id"]]
        if groups:
            args.append("--groups")
        if event["kind"] == "answer":
            args.extend(("--answer-id", event["event_id"]))
        else:
            if not groups:
                args.append("--shared")
            args.extend(("--entry-id", event["event_id"]))
        result = self.cli.mutation(self.journal, operation_id, args)
        if result["kind"] != "committed":
            print("Harklight refused a receipt for an accepted event", file=sys.stderr)

    def follow_args(self, checkpoint: dict) -> list[str]:
        return [
            *self.cli.argv, "listen", "--follow", "--groups" if checkpoint.get("groups") else "--shared",
            "--session", self.session, "--ack2",
            "--after", str(checkpoint["rev"]), "--continuation", checkpoint["continuation"],
            "--on-expired", "exit",
        ]

    def changes(self, checkpoint: dict | None):
        if not self.shared:
            return
        scope = "--groups" if self.groups else "--shared"
        args = ["read", scope, "--session", self.session, "--ack2"]
        if checkpoint is None or bool(checkpoint.get("groups")) != self.groups:
            start = self.cli.one(*args, "--pending", "--prepare")
            if start.get("kind") != "baseline_prepared" or start.get("shared_events") is not True:
                raise RuntimeError("Harklight did not prepare a shared baseline")
            checkpoint = {"rev": start["rev"], "continuation": start["continuation"],
                          "token": start["token"], "groups": self.groups}
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
                    "groups": self.groups,
                }
            elif "data" in row and "rev" in row:
                position = (
                    checkpoint if baseline else
                    {"rev": row["rev"], "continuation": checkpoint["continuation"], "groups": self.groups}
                )
                yield self.server_id, row, position
