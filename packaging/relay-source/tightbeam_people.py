"""The relay-facing Tightbeam people-message commands."""

from __future__ import annotations

import json
import subprocess


class TightbeamRefusal(RuntimeError):
    def __init__(self, command: str, status: int, error: dict):
        super().__init__(f"Tightbeam {command} refused ({error['code']})")
        self.status = status
        self.error = error


class TightbeamPeople:
    def call(self, command: str, payload: dict) -> dict | None:
        result = subprocess.run(
            ["tightbeam", command, "--json", json.dumps(payload)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode:
            for line in result.stderr.splitlines():
                try:
                    response = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(response, dict):
                    continue
                status = response.get("httpStatus")
                error = response.get("error")
                if (type(status) is not int or not 400 <= status < 500
                        or not isinstance(error, dict) or not isinstance(error.get("code"), str)):
                    continue
                if command == "people-lookup" and status == 404 and error["code"] == "not_found":
                    return None
                raise TightbeamRefusal(command, status, error)
            raise RuntimeError(f"Tightbeam {command} exited {result.returncode}")
        return json.loads(result.stdout)

    @staticmethod
    def wait_args() -> list[str]:
        return ["tightbeam", "people-wait", "--json",
                json.dumps({"limit": 50, "timeout_ms": 15000})]

    def collect(self, limit: int = 100) -> list[dict]:
        return self.call("people-collect", {"limit": limit})["records"]

    def report(self, report: dict) -> None:
        self.accept("people-report", report)

    def event(self, event: dict) -> None:
        self.accept("people-event", event)

    def accept(self, command: str, payload: dict) -> None:
        response = self.call(command, payload)
        if response.get("accepted") is not True or type(response.get("duplicate")) is not bool:
            raise RuntimeError(f"Tightbeam {command} did not confirm acceptance")

    def lookup(self, server_id: str, item_id: str) -> dict | None:
        return self.call("people-lookup", {
            "server_id": server_id, "remote_conversation_id": item_id,
        })
