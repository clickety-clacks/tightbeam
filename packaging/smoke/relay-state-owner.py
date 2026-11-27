#!/usr/bin/env python3
"""Verify finite and watch entrypoints respect the same state-directory lock."""

import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(relay):
    with tempfile.TemporaryDirectory(prefix="tightbeam-relay-lock-") as scratch:
        home = Path(scratch)
        state = home / "state"
        state.mkdir(mode=0o700)
        config = home / "config.json"
        config.write_text(json.dumps({
            "connection": str(home / "offline-agent"),
            "sender": "service:synthetic",
            "users": {},
        }))
        database = state / "relay.db"
        untouched = b"synthetic prior state\n"
        database.write_bytes(untouched)
        with (state / "run.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for label, mode in (("finite", []), ("watch", ["--watch"])):
                command = [sys.executable, str(relay), "--config", str(config),
                           "--state-dir", str(state), *mode]
                result = subprocess.run(command, capture_output=True, text=True, timeout=10,
                                        env={"HOME": str(home), "PATH": "", "LC_ALL": "C",
                                             "PYTHONDONTWRITEBYTECODE": "1"})
                refusal = "another relay already owns this state directory"
                if mode:
                    if result.returncode != 1 or refusal not in result.stderr.lower():
                        raise SystemExit("competing relay watcher did not report the held state lock")
                elif result.returncode != 0 or result.stdout or result.stderr:
                    raise SystemExit("competing finite relay did not exit quietly")
                if database.read_bytes() != untouched or set(os.listdir(state)) != {"run.lock", "relay.db"}:
                    raise SystemExit("a competing relay changed existing state")
                print(f"relay {label}: held state lock prevented runtime operations")


if __name__ == "__main__":
    check(Path(sys.argv[1]).resolve())
