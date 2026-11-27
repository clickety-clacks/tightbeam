#!/usr/bin/env python3
"""Generate a public SQLite dump from a verified Linux release archive."""
import argparse
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 1_000_000
REQUIRED_TABLES = (
    "sessions", "assignments", "attests", "artifacts", "wakes",
    "decision_requests", "work_items", "users", "schema_stamp",
)
GENERATED_VALUE = re.compile(
    r"(?P<uuid>[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})"
    r"|(?P<short>(?:wi|art|dr|asg|at)_[0-9a-f]{8,32})\b"
    r"|(?P<token>tb[a-z]*_[A-Za-z0-9_-]{24,})"
)


def canonical_dump(db, scratch):
    dump = subprocess.check_output(["sqlite3", "-batch", "-bail", db, ".dump"], text=True)
    values = {}

    def canonical_value(match):
        value = match[0]
        if value not in values:
            index = len(values) + 1
            if match.lastgroup == "uuid":
                replacement = f"00000000-0000-4000-8000-{index:012x}"
            elif match.lastgroup == "short":
                prefix, suffix = value.split("_")
                replacement = f"{prefix}_{index:0{len(suffix)}x}"
            else:
                replacement = f"fixture-token-{index}"
            values[value] = replacement
        return values[value]

    # Startup and command handlers create the rows. Normalize generated IDs and
    # the disposable environment in the export, retaining references between rows.
    lines = []
    for line in dump.splitlines(keepends=True):
        if not line.startswith((".restrict ", ".unrestrict ")):
            line = GENERATED_VALUE.sub(canonical_value, line.replace(str(scratch), "/fixture"))
            lines.append(line)
    return "".join(lines)


def generate(archive, faketime, output):
    with tempfile.TemporaryDirectory(prefix="tightbeam-fixture-") as tmp:
        scratch = Path(tmp)
        for folder in ("home", "tools", "base"):
            (scratch / folder).mkdir()
        subprocess.run(
            ["tar", "-xzf", archive, "-C", scratch], check=True, timeout=60
        )
        claude = scratch / "tools/claude"
        claude.write_text('#!/bin/sh\n[ "${1-}" = --version ] || exit 64\necho "2.1.280"\n')
        claude.chmod(0o700)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = {
            "PATH": f"{scratch / 'tools'}:{os.environ['PATH']}",
            "HOME": str(scratch / "home"),
            "TMPDIR": str(scratch),
            "LC_ALL": "C",
            "TZ": "UTC",
            "TIGHTBEAM_BASE_DIR": str(scratch / "base"),
            "TIGHTBEAM_PORT": str(port),
            "TIGHTBEAM_DEFAULT_HARNESS": "claude",
            "TIGHTBEAM_LOCAL_HOST_NAME": "fixture",
            "TB_FIXTURE_SEED": str(ROOT / "scripts/seed_release_fixture.exs"),
            "ERL_FLAGS": "+S 2:2 +SDcpu 1 +SDio 1",
            "LD_PRELOAD": str(faketime),
            "FAKETIME": "2025-01-01 00:00:00",
            "FAKETIME_DONT_FAKE_MONOTONIC": "1",
        }
        subprocess.run(
            [scratch / "tightbeam/bin/tightbeam-gateway", "eval",
             'false = Node.alive?(); {:ok, _} = Application.ensure_all_started(:tightbeam); '
             'Code.require_file(System.fetch_env!("TB_FIXTURE_SEED")); '
             ':ok = Application.stop(:tightbeam)'],
            cwd=scratch, env=env, check=True, timeout=120,
        )
        db = scratch / "base/state.db"
        dump = canonical_dump(db, scratch)
        size = len(dump.encode())
        if size > LIMIT:
            raise SystemExit(f"Release fixture is {size} bytes (limit {LIMIT}). Stopped.")
        with sqlite3.connect(scratch / "restored.db") as restored:
            restored.executescript(dump)
            if restored.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise ValueError("fixture failed integrity_check")
            if restored.execute("PRAGMA foreign_key_check").fetchall():
                raise ValueError("fixture failed foreign_key_check")
            for table in REQUIRED_TABLES:
                if restored.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone() is None:
                    raise ValueError(f"release seed left {table} empty")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(dump, encoding="utf-8")
        print(f"Generated {output.name} ({size} bytes)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--faketime", type=Path, required=True)
    args = parser.parse_args()
    generate(args.archive.resolve(), args.faketime.resolve(), args.output.resolve())
