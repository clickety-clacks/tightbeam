"""Subprocess boundary for the installed Harklight Agent."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess


class AgentCLI:
    def __init__(self, connection: str, state_dir: Path):
        self.argv = ["harklight-agent", "--identity-dir", connection,
                     "--state-dir", str(state_dir)]

    def run(self, *args: str) -> tuple[int, list[dict]]:
        result = subprocess.run(
            [*self.argv, *args], capture_output=True, text=True, timeout=30,
        )
        return result.returncode, [json.loads(line) for line in result.stdout.splitlines()]

    def one(self, *args: str) -> dict:
        status, rows = self.run(*args)
        if status or len(rows) != 1:
            raise RuntimeError(f"Harklight Agent {args[0]} did not return one successful result")
        return rows[0]

    def mutation(self, journal_id: str, operation_id: str, args: list[str], *, prepare: bool = False) -> dict:
        status, rows = self.run(
            "retry", "--op-id", operation_id, "--journal-id", journal_id,
        )
        if status == 1 and len(rows) == 1 and rows[0] == {
            "kind": "operation_absent", "op_id": operation_id, "journal_id": journal_id,
        }:
            if prepare:
                status, rows = self.run(*args, "--op-id", operation_id, "--prepare")
                if status == 0 and len(rows) == 1 and rows[0].get("kind") == "prepared":
                    if rows[0].get("op_id") != operation_id:
                        raise RuntimeError("Harklight Agent prepared the wrong operation")
                    status, rows = self.run("send", "--execute", "--op-id", operation_id)
            else:
                status, rows = self.run(*args, "--op-id", operation_id)
        if len(rows) == 1 and rows[0].get("op_id") == operation_id:
            row = rows[0]
            if status == 0 and row["kind"] == "committed":
                return row
            if status in {2, 5} and row["kind"] == "refused":
                return row
        raise RuntimeError(f"Harklight Agent {args[0]} outcome is unresolved")
