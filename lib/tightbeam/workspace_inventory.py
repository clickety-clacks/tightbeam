"""Read-only inventory run on the retired workspace's host."""

import hashlib
import os
import stat
import subprocess
import sys


def emit(tag, *fields):
    sys.stdout.buffer.write(os.fsencode("\t".join((tag, *map(str, fields))) + "\n"))


def encoded(path):
    return os.fsencode(path).hex()


def regenerable(path, rel, mode):
    name = os.path.basename(rel)
    parent = os.path.dirname(path)
    if rel in (".tightbeam-session", ".tightbeam-effort", ".DS_Store"):
        return not stat.S_ISDIR(mode)
    if os.path.dirname(rel) in (".claude/skills", ".codex/skills", ".agents/skills"):
        if name.startswith("tightbeam__"):
            return stat.S_ISDIR(mode) or stat.S_ISLNK(mode)
    if not stat.S_ISDIR(mode):
        return name == ".DS_Store"
    if name in (".cache", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"):
        return True
    if name == ".venv":
        return os.path.isfile(os.path.join(path, "pyvenv.cfg"))
    marker = {
        "_build": "mix.exs",
        "deps": "mix.exs",
        "target": "Cargo.toml",
        "node_modules": "package.json",
        ".gradle": "settings.gradle",
    }.get(name)
    return marker is not None and os.path.isfile(os.path.join(parent, marker))


def entry_mode(path):
    try:
        return os.lstat(path).st_mode
    except FileNotFoundError:
        return 0


def checkout(path):
    marker = entry_mode(os.path.join(path, ".git"))
    if stat.S_ISREG(marker) or stat.S_ISDIR(marker):
        return True
    if not (
        stat.S_ISREG(entry_mode(os.path.join(path, "HEAD")))
        and os.path.isdir(os.path.join(path, "objects"))
        and os.path.isdir(os.path.join(path, "refs"))
    ):
        return False
    result = subprocess.run(
        ["git", "-c", "safe.directory=*", "-C", path, "rev-parse", "--is-bare-repository"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0 and result.stdout.strip() == b"true"


def inventory(root, protected):
    device = os.lstat(root).st_dev

    def walk(path, rel):
        if "\n" in rel or "\r" in rel:
            raise ValueError("unsupported_newline_path", rel)
        if rel in protected:
            return
        info = os.lstat(path)
        if info.st_dev != device:
            raise ValueError("mount_boundary", rel)
        mode = info.st_mode
        if regenerable(path, rel, mode):
            return
        if stat.S_ISDIR(mode):
            if checkout(path):
                return
            names = sorted(os.listdir(path))
            yield rel, b"d", 0
            for name in names:
                yield from walk(os.path.join(path, name), os.path.join(rel, name))
        elif stat.S_ISLNK(mode):
            yield rel, b"l", info.st_size
        elif stat.S_ISREG(mode):
            yield rel, b"f", info.st_size
        else:
            raise ValueError("unrecorded_file_type_unsupported", rel)

    if "." not in protected and not checkout(root):
        # Keep individual scopes readable and their acknowledgement keys
        # small enough to pass back to the host. The root scope covers overflow.
        overflow = []
        scope_count = 0
        for name in sorted(os.listdir(root)):
            entries = list(walk(os.path.join(root, name), name))
            if not entries:
                continue
            if scope_count < 127:
                yield name, entries
                scope_count += 1
            else:
                overflow.extend(entries)
        if overflow:
            yield ".", overflow


def digest(root, entries):
    state = hashlib.sha256()
    for rel, kind, size in entries:
        state.update(kind + b"\0" + os.fsencode(rel) + b"\0" + str(size).encode() + b"\0")
        path = os.path.join(root, rel)
        if kind == b"l":
            state.update(hashlib.sha256(os.fsencode(os.readlink(path))).digest())
        elif kind == b"f":
            contents = hashlib.sha256()
            with open(path, "rb") as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b""):
                    contents.update(chunk)
            state.update(contents.digest())
    return state.hexdigest()


def admit(destination, size, reserve_bytes, reserve_percent):
    if not destination:
        return False
    parent = os.path.dirname(destination)
    while not os.path.exists(parent):
        parent = os.path.dirname(parent)
    capacity = os.statvfs(parent)
    free = capacity.f_bavail * capacity.f_frsize
    reserved = max(reserve_bytes, capacity.f_blocks * capacity.f_frsize * reserve_percent // 100)
    return free - size >= reserved


def main():
    root, destination, *limits = sys.argv[1:]
    max_entries, max_bytes, reserve_bytes, reserve_percent = map(int, limits)
    keep, acknowledged = sys.stdin.buffer.read().split(b"\0", 1)
    protected = set(os.fsdecode(keep).split("\n"))
    acknowledged = set(os.fsdecode(acknowledged).split("\n"))
    scopes = list(inventory(root, protected))
    if not scopes:
        return

    summaries = {
        scope: (len(entries), sum(size for _, _, size in entries))
        for scope, entries in scopes
    }
    total_entries = sum(count for count, _ in summaries.values())
    total_size = sum(size for _, size in summaries.values())
    over_budget = total_entries > max_entries or total_size > max_bytes
    reason = "archive_budget_exceeded" if over_budget else "archive_reserve"
    archive = not over_budget and admit(destination, total_size, reserve_bytes, reserve_percent)

    # Acknowledge only a fully inventoried over-budget scope, never a scan error.
    for scope, entries in scopes:
        count, size = summaries[scope]
        if archive:
            for rel, kind, _ in entries:
                emit("D" if kind == b"d" else "K", rel)
            outcome = "archive"
        else:
            state = digest(root, entries)
            try:
                scope.encode("utf-8")
                report_path = scope
            except UnicodeEncodeError:
                report_path = "hex:" + encoded(scope)
            if f"unrecorded:{report_path}@{state}" in acknowledged:
                outcome = "acknowledged"
            else:
                outcome = "held"
                emit("L", "unrecorded", encoded(scope),
                     f"entries={count} bytes={size} reason={reason} state={state}")
        emit("U", encoded(scope), count, size, outcome)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        if len(error.args) != 2:
            raise
        emit("E", error.args[0], encoded(error.args[1]))
        sys.exit(1)
    except OSError:
        emit("E", "unrecorded_inventory_unavailable", "2e")
        sys.exit(1)
