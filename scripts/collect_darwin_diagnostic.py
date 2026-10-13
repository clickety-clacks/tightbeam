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
LLDB_PROMPT_RE = re.compile(r"^\(lldb\)\s*(.*)$")
BREAKPOINT_RE = re.compile(
    r"^\s*Breakpoint ([0-9]+):.*(?:`| )abort(?:\b|[+ ])"
)
PROCESS_STOPPED_RE = re.compile(r"^\s*Process ([0-9]+) stopped\b")
STOP_REASON_RE = re.compile(
    r"^\s*(?:\* )?thread #([0-9]+).*stop reason = breakpoint ([0-9]+)\.([0-9]+)\b"
)
LLDB_ERROR_RE = re.compile(r"^\s*error:")


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


def gate_status(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 32:
        return None
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return int(value) if re.fullmatch(r"-?[0-9]+", value) else None


def parse_backtrace(text):
    thread = None
    frames = []
    for line in text.splitlines():
        match = THREAD_RE.match(line)
        if match:
            current = int(match.group(1))
            if thread is None:
                thread = current
            elif current != thread:
                return None, []
            continue
        if thread is None:
            continue
        match = FRAME_RE.match(line)
        if not match or match.group(4) is None:
            continue
        module = Path(match.group(2).strip()).name
        symbol = match.group(3)
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", module):
            continue
        if not re.fullmatch(r"[A-Za-z0-9_.$?~:+<>,()\[\]-]+", symbol):
            continue
        try:
            offset = int(match.group(4), 0)
        except ValueError:
            continue
        frames.append({
            "frame": int(match.group(1)),
            "module": module,
            "symbol": symbol,
            "offset": offset,
        })
        if len(frames) == 32:
            break
    return thread, frames


def parse_lldb_capture(text, pid):
    """Parse only the selected-thread backtrace command after an abort stop."""
    abort_breakpoints = set()
    stopped_pid = None
    abort_stop = None
    backtrace_segment = None
    backtrace_error = False

    for line in text.splitlines():
        prompt = LLDB_PROMPT_RE.match(line)
        if prompt:
            command = prompt.group(1).strip()
            if command == "thread backtrace -c 32":
                backtrace_segment = []
                backtrace_error = False
                continue
            if backtrace_segment is not None:
                break
            continue

        match = BREAKPOINT_RE.match(line)
        if match:
            abort_breakpoints.add(int(match.group(1)))

        match = PROCESS_STOPPED_RE.match(line)
        if match:
            stopped_pid = int(match.group(1))

        match = STOP_REASON_RE.match(line)
        if (
            match
            and stopped_pid == pid
            and int(match.group(2)) in abort_breakpoints
        ):
            abort_stop = {
                "thread": int(match.group(1)),
                "breakpoint": int(match.group(2)),
                "location": int(match.group(3)),
            }

        if backtrace_segment is not None:
            if LLDB_ERROR_RE.match(line):
                backtrace_error = True
            backtrace_segment.append(line)

    if not abort_breakpoints:
        return "abort-breakpoint-not-verified", None
    if abort_stop is None:
        return "abort-stop-not-observed", None
    if backtrace_segment is None:
        return "backtrace-command-not-observed", None
    if backtrace_error:
        return "backtrace-failed", None

    thread, frames = parse_backtrace("\n".join(backtrace_segment))
    if thread != abort_stop["thread"]:
        return "selected-thread-mismatch", None
    if not frames:
        return "backtrace-empty", None
    return "captured", {
        "thread": thread,
        "breakpoint": abort_stop["breakpoint"],
        "stopReason": "breakpoint {}.{}".format(
            abort_stop["breakpoint"], abort_stop["location"]
        ),
        "frames": frames,
    }



def apply_lldb_capture(result, text, pid, exit_code):
    """Apply capture only while the observer still has a nonterminal status."""
    if result.get("status") != "watcher-started":
        return
    if exit_code != 0:
        result["status"] = "debugger-attach-failed"
        return
    status, capture = parse_lldb_capture(text, pid)
    result["status"] = status
    if capture is not None:
        result.update(capture)
        result["capturedAtMs"] = int(time.time() * 1000)


def parser_controls():
    """Keep synthetic parser controls beside the sanitized parser contract."""
    pid = 4242
    positive = """Breakpoint 1: where = libsystem_c.dylib`abort + 4
(lldb) continue
Process 4242 stopped
* thread #7, stop reason = breakpoint 1.1
(lldb) thread backtrace -c 32
* thread #7, stop reason = breakpoint 1.1
  frame #0: 0x0000000180000000 libsystem_c.dylib`abort + 4
  frame #1: 0x0000000180000010 beam.smp`raise_abort + 16
(lldb) detach
"""

    status, capture = parse_lldb_capture(positive, pid)
    if status != "captured" or capture["thread"] != 7 or len(capture["frames"]) != 2:
        raise RuntimeError("positive parser control failed")

    attach_failed = {"status": "watcher-started"}
    apply_lldb_capture(attach_failed, positive, pid, 1)
    if attach_failed["status"] != "debugger-attach-failed":
        raise RuntimeError("attach-failure parser control failed")

    unrelated = positive.replace(
        "stop reason = breakpoint 1.1", "stop reason = signal = SIGSTOP"
    )
    status, capture = parse_lldb_capture(unrelated, pid)
    if status != "abort-stop-not-observed" or capture is not None:
        raise RuntimeError("unrelated-stop parser control failed")

    failed_backtrace = positive.replace(
        "* thread #7, stop reason = breakpoint 1.1\n  frame #0: 0x0000000180000000 libsystem_c.dylib`abort + 4\n  frame #1: 0x0000000180000010 beam.smp`raise_abort + 16",
        "error: thread backtrace failed",
    )
    status, capture = parse_lldb_capture(failed_backtrace, pid)
    if status != "backtrace-failed" or capture is not None:
        raise RuntimeError("failed-backtrace parser control failed")

    for terminal in ("debugger-timeout", "gate-succeeded"):
        result = {"status": terminal}
        apply_lldb_capture(result, positive, pid, 0)
        if result["status"] != terminal:
            raise RuntimeError("terminal-status parser control failed")

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
    exit_path = directory / "exit.txt"
    seen = result["lifecycleObservedAtMs"]

    try:
        parser_controls()
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
            if gate_status(exit_path) is not None:
                result["status"] = "gate-finished-before-vm-receipt"
                return publish(directory, "backtrace.json", result)
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
            "thread backtrace -c 32",
            "-o",
            "detach",
            "-o",
            "quit",
        ]
        with raw_path.open("wb") as raw:
            process = subprocess.Popen(args, stdout=raw, stderr=subprocess.STDOUT)
            while process.poll() is None:
                scan_lifecycle(log, seen)
                if gate_status(exit_path) == 0:
                    process.terminate()
                    result["status"] = "gate-succeeded"
                    break
                if time.monotonic() >= deadline:
                    process.kill()
                    result["status"] = "debugger-timeout"
                    break
                time.sleep(0.1)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                result["status"] = "debugger-timeout"
            result["debuggerExitCode"] = process.returncode
        result["attachFinishedAtMs"] = int(time.time() * 1000)
        scan_lifecycle(log, seen)
        if result["status"] == "watcher-started" and gate_status(exit_path) == 0:
            result["status"] = "gate-succeeded"
        text = raw_path.read_text(encoding="utf-8", errors="replace")
        apply_lldb_capture(result, text, pid, result["debuggerExitCode"])
        if result["status"] == "backtrace-command-not-observed":
            result["status"] = "no-symbolized-abort-backtrace"
    except RuntimeError:
        if result["status"] == "watcher-started":
            result["status"] = "parser-controls-failed"
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
