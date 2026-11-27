"""Read complete JSON frames from a supervised CLI subprocess."""

from __future__ import annotations

import json
import os
import selectors
import subprocess
import tempfile


class RelayProcess:
    def __init__(self, selector: selectors.BaseSelector, args: list[str], role: str):
        self.role = role
        self.stderr = tempfile.TemporaryFile() if role == "readiness" else None
        try:
            self.process = subprocess.Popen(
                args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=self.stderr,
            )
        except BaseException:
            if self.stderr is not None:
                self.stderr.close()
            raise
        self.selector = selector
        self.pending = b""
        try:
            selector.register(self.process.stdout, selectors.EVENT_READ, role)
        except BaseException:
            self.close()
            raise

    def frames(self) -> tuple[list[dict], bool]:
        chunk = os.read(self.process.stdout.fileno(), 65536)
        if self.role == "readiness":
            self.pending += chunk
            if chunk:
                return [], False
            if not self.pending.strip():
                return [], True
            frame = json.loads(self.pending)
            if not isinstance(frame, dict):
                raise ValueError("Tightbeam people-wait emitted a non-object JSON result")
            return [frame], True
        if not chunk:
            if self.pending:
                raise RuntimeError("Relay child ended with an incomplete JSON frame")
            return [], True
        *lines, self.pending = (self.pending + chunk).split(b"\n")
        frames = [json.loads(line) for line in lines if line.strip()]
        if any(not isinstance(frame, dict) for frame in frames):
            raise ValueError("Relay child emitted a non-object JSON frame")
        return frames, False

    def result(self) -> tuple[int, str]:
        status = self.process.wait(timeout=2)
        self.stderr.seek(0)
        return status, self.stderr.read(65536).decode(errors="replace")

    def close(self) -> None:
        try:
            self.selector.unregister(self.process.stdout)
        except KeyError:
            pass
        self.process.stdout.close()
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.stderr is not None:
            self.stderr.close()
