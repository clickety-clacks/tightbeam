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


WATCH_SECONDS = 900
LIFECYCLE_MARKERS = {
    "native-lock-ready": re.compile(r"^native-lock-ready$", re.MULTILINE),
    "native-lock-kill-result": re.compile(r"^native-lock-kill-result: \{", re.MULTILINE),
    "native-lock-sigkill": re.compile(r"^native-lock-sigkill: ok$", re.MULTILINE),
    "native-lock-cleanup-exit": re.compile(
        r"^native-lock-cleanup-exit: [0-9]+$", re.MULTILINE
    ),
}
THREAD_RE = re.compile(r"^\s*(?:\* )?thread #([0-9]+)\b")
FRAME_RE = re.compile(
    r"^\s*(?:\* )?frame #([0-9]+):\s+0x[0-9A-Fa-f]+\s+([^`\r\n]+)`([^\s\r\n]+)"
    r"(?:\s+\+\s+(0x[0-9A-Fa-f]+|[0-9]+))?"
)


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


def scan_lifecycle(log, seen):
    if log.is_symlink() or not log.is_file() or log.stat().st_size > 8_000_000:
        return
    try:
        text = log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    observed = int(time.time() * 1000)
    for name, marker in LIFECYCLE_MARKERS.items():
        if name not in seen and marker.search(text):
            seen[name] = observed


def parse_backtrace(text):
    thread = None
    frames = []
    for line in text.splitlines():
        if thread is None:
            match = THREAD_RE.match(line)
            if match:
                thread = int(match.group(1))
        match = FRAME_RE.match(line)
        if not match or match.group(4) is None:
            continue
        module = Path(match.group(2).strip()).name
        symbol = match.group(3)
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", module):
            continue
        if not re.fullmatch(r"[A-Za-z0-9_.$?~:+<>,()\[\]-]+", symbol):
            continue
        frames.append(
            {
                "frame": int(match.group(1)),
                "module": module,
                "symbol": symbol,
                "offset": int(match.group(4), 0),
            }
        )
        if len(frames) == 32:
            break
    return thread, frames


def watch(directory, candidate):
    """Attach once to the owned test VM and publish only a sanitized backtrace."""
    result = {
        "schema": "tightbeam-darwin-backtrace/v1",
        "candidate": candidate,
        "status": "watcher-started",
        "watcherStartedAtMs": int(time.time() * 1000),
        "lifecycleObservedAtMs": {},
    }
    raw_path = directory / "backtrace.raw"
    log = directory / "full.log"
    seen = result["lifecycleObservedAtMs"]

    try:
        runtime = read_json(directory / "runtime.json")
        if runtime.get("candidate") != candidate:
            raise ValueError("candidate mismatch")
        debugger = runtime.get("debuggerPath")
        if (
            not isinstance(debugger, str)
            or Path(debugger).name != "lldb"
            or not Path(debugger).is_file()
        ):
            result["status"] = "debugger-unavailable"
            return publish(directory, "backtrace.json", result)

        deadline = time.monotonic() + WATCH_SECONDS
        receipt = None
        while time.monotonic() < deadline:
            scan_lifecycle(log, seen)
            try:
                receipt = read_json(directory / "vm.json")
                if receipt.get("candidate") != candidate:
                    raise ValueError("candidate mismatch")
                if type(receipt.get("pid")) is not int or receipt["pid"] <= 0:
                    raise ValueError("invalid PID")
                break
            except (FileNotFoundError, OSError, ValueError, KeyError, TypeError):
                time.sleep(0.1)
        if receipt is None:
            result["status"] = "vm-receipt-unavailable"
            return publish(directory, "backtrace.json", result)

        pid = receipt["pid"]
        result["pid"] = pid
        result["vmStartedAtMs"] = receipt.get("startedAtMs")
        result["attachStartedAtMs"] = int(time.time() * 1000)
        args = [
            debugger,
            "--batch",
            "--no-lldbinit",
            "-p",
            str(pid),
            "-o",
            "breakpoint set --name abort",
            "-o",
            "continue",
            "-o",
            "thread backtrace",
            "-o",
            "detach",
            "-o",
            "quit",
        ]
        with raw_path.open("wb") as raw:
            process = subprocess.Popen(args, stdout=raw, stderr=subprocess.STDOUT)
            while process.poll() is None:
                scan_lifecycle(log, seen)
                if time.monotonic() >= deadline:
                    process.kill()
                    result["status"] = "debugger-timeout"
                    break
                time.sleep(0.1)
            process.wait()
        result["attachFinishedAtMs"] = int(time.time() * 1000)
        scan_lifecycle(log, seen)
        text = raw_path.read_text(encoding="utf-8", errors="replace")
        thread, frames = parse_backtrace(text)
        if frames:
            result["status"] = "captured"
            result["thread"] = thread
            result["frames"] = frames
            result["capturedAtMs"] = int(time.time() * 1000)
        elif result["status"] == "watcher-started":
            result["status"] = "no-symbolized-abort-backtrace"
    except (OSError, ValueError, KeyError, TypeError, UnicodeError):
        if result["status"] == "watcher-started":
            result["status"] = "debugger-attach-failed"
    finally:
        try:
            raw_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            result["rawCleanup"] = "failed"
    publish(directory, "backtrace.json", result)


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
        backtrace = directory / "backtrace.json"
        deadline = time.monotonic() + 15
        while not backtrace.is_file() and time.monotonic() < deadline:
            time.sleep(0.1)
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
    if len(sys.argv) != 4 or sys.argv[1] not in {"prepare", "watch", "collect"}:
        raise ValueError("expected prepare|watch|collect directory candidate")
    operation, raw, candidate = sys.argv[1:]
    directory, root = Path(raw), Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if not re.fullmatch(r"[0-9a-f]{40}", candidate):
        raise ValueError("invalid candidate")
    if directory.is_symlink() or directory.resolve(strict=True) != directory or root not in directory.parents:
        raise ValueError("diagnostic directory outside canonical runner temp")
    if not directory.is_dir():
        raise ValueError("diagnostic directory missing")
    if operation == "prepare":
        prepare(directory, candidate)
    elif operation == "watch":
        watch(directory, candidate)
    else:
        collect(directory, candidate)


if __name__ == "__main__":
    main()
