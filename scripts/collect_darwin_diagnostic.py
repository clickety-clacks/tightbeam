#!/usr/bin/env python3
"""Owned test-VM evidence only. Never export a raw crash report or process memory."""
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def publish(directory, name, value):
    pending = directory / (name + ".pending")
    with pending.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True)
        stream.write("\n")
    pending.replace(directory / name)


def read_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 8_000_000:
        raise ValueError("invalid evidence file")
    return json.loads(path.read_text(encoding="utf-8"))


def command(argv):
    result = subprocess.run(argv, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError("diagnostic facility unavailable: " + argv[0])
    return result.stdout.strip()


def prepare(directory, candidate):
    if sys.platform != "darwin" or command(["uname", "-m"]) != "arm64":
        raise RuntimeError("requires existing Darwin arm64 route")
    if command(["git", "rev-parse", "HEAD"]) != candidate:
        raise RuntimeError("candidate mismatch")
    publish(directory, "runtime.json", {
        "candidate": candidate,
        "startedAtMs": int(time.time() * 1000),
        "os": command(["sw_vers"]),
        "architecture": "arm64",
        "debuggerPath": command(["xcrun", "--find", "lldb"]),
        "debuggerVersion": command(["xcrun", "lldb", "--version"]),
        "beam": command(["elixir", "--version"]),
        "rust": command(["rustc", "--version"]),
    })


def select_fields(value, fields):
    if not isinstance(value, dict):
        raise ValueError("unsupported field object")
    selected = {}
    for key, expected in fields.items():
        if key in value:
            item = value[key]
            if type(item) is not expected or (expected is str and len(item) > 4096):
                raise ValueError("unsupported field type")
            selected[key] = item
    return selected


def filter_report(path, receipt, begin, end):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 8_000_000:
        return None
    if not begin <= path.stat().st_mtime * 1000 <= end:
        return None
    encoded = path.read_text(encoding="utf-8")
    decoder = json.JSONDecoder()
    first, offset = decoder.raw_decode(encoded)
    rest = encoded[offset:].strip()
    body = json.loads(rest) if rest else first
    if not isinstance(body, dict) or body.get("pid") != receipt["pid"]:
        return None
    if body.get("procName") != "beam.smp" or body.get("procPath") != receipt["executable"]:
        return None
    timestamp = datetime.datetime.fromisoformat(body["captureTime"])
    if timestamp.tzinfo is None or not begin <= timestamp.timestamp() * 1000 <= end:
        return None
    faulting = body["faultingThread"]
    threads, images = body["threads"], body["usedImages"]
    if type(faulting) is not int or not isinstance(threads, list) or not isinstance(images, list):
        raise ValueError("unsupported crash shape")
    if not 0 <= faulting < len(threads):
        raise ValueError("invalid crashing-thread index")
    frame_fields = {"imageIndex": int, "imageOffset": int, "symbol": str, "symbolLocation": int}
    image_fields = {"name": str, "path": str, "uuid": str, "arch": str, "base": int, "size": int}
    frames = threads[faulting]["frames"]
    if not isinstance(frames, list) or not frames:
        raise ValueError("missing crashing-thread frames")
    filtered = [select_fields(frame, frame_fields) for frame in frames]
    if any(not 0 <= frame.get("imageIndex", -1) < len(images) for frame in filtered):
        raise ValueError("invalid frame image index")
    filtered_images = [select_fields(image, image_fields) for image in images]
    for frame in filtered:
        if not {"path", "uuid", "base", "size"} <= filtered_images[frame["imageIndex"]].keys():
            raise ValueError("missing loaded-library identity")
    return {
        "status": "captured", "candidate": receipt["candidate"],
        "pid": receipt["pid"], "executable": receipt["executable"],
        "faultingThread": faulting,
        "exception": select_fields(body["exception"], {"type": str, "signal": str}),
        "frames": filtered,
        "usedImages": filtered_images,
    }


def collect(directory, candidate):
    try:
        receipt, runtime = read_json(directory / "vm.json"), read_json(directory / "runtime.json")
        if receipt["candidate"] != candidate or runtime["candidate"] != candidate:
            raise ValueError("candidate mismatch")
        if type(receipt["pid"]) is not int or receipt["pid"] <= 0:
            raise ValueError("invalid PID")
        begin = max(runtime["startedAtMs"], receipt["startedAtMs"])
        end = time.time() * 1000 + 10_000
        reports = Path.home() / "Library/Logs/DiagnosticReports"
        deadline = time.monotonic() + 10
        status = "no-matching-report"
        while True:
            try:
                # Directory access itself must be proven; a silent empty glob is insufficient.
                entries = list(reports.iterdir())
                for path in entries:
                    if path.name.startswith("beam.smp-") and path.suffix == ".ips":
                        try:
                            result = filter_report(path, receipt, begin, end)
                        except (ValueError, KeyError, TypeError, UnicodeError):
                            status = "unsupported-report-shape"
                            continue
                        if result is not None:
                            publish(directory, "crash.json", result)
                            return
            except OSError:
                status = "report-directory-unavailable"
                break
            if time.monotonic() >= deadline:
                break
            time.sleep(min(0.25, max(0, deadline - time.monotonic())))
        publish(directory, "crash.json", {"status": status, "candidate": candidate})
    except (OSError, ValueError, KeyError, TypeError):
        publish(directory, "crash.json", {"status": "receipt-unavailable-or-invalid", "candidate": candidate})


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in {"prepare", "collect"}:
        raise ValueError("expected prepare|collect directory candidate")
    operation, raw, candidate = sys.argv[1:]
    directory, root = Path(raw), Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if not re.fullmatch(r"[0-9a-f]{40}", candidate):
        raise ValueError("invalid candidate")
    if directory.is_symlink() or directory.resolve(strict=True) != directory or root not in directory.parents:
        raise ValueError("diagnostic directory outside canonical runner temp")
    if not directory.is_dir():
        raise ValueError("diagnostic directory missing")
    (prepare if operation == "prepare" else collect)(directory, candidate)


if __name__ == "__main__":
    main()
