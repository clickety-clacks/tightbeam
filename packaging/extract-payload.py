#!/usr/bin/env python3
"""Extract only a fully validated, regular-file package into an empty private directory."""
import pathlib
import shutil
import sys
import tarfile

def reject_distribution_member(name):
    if name.casefold() in {"cookie", ".erlang.cookie", "erlang.cookie",
                            "debug-distribution.cookie", "distribution.cookie", "release.cookie"}:
        raise ValueError("forbidden distribution credential member")


if sys.argv[1:2] == ["--tree"]:
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract-payload.py --tree <assembly-root>")
    tree = pathlib.Path(sys.argv[2])
    if not tree.is_dir() or tree.is_symlink():
        raise SystemExit("payload tree refused: expected assembly directory")
    try:
        for entry in tree.rglob("*"):
            reject_distribution_member(entry.name)
    except (ValueError, OSError) as error:
        raise SystemExit("payload tree refused: " + str(error))
    sys.exit(0)

inventory_only = sys.argv[1:2] == ["--inventory-only"]
if len(sys.argv) != 3:
    raise SystemExit("usage: extract-payload.py <archive> <destination> | --inventory-only <archive>")
archive = sys.argv[2] if inventory_only else sys.argv[1]
root = None if inventory_only else pathlib.Path(sys.argv[2])
if root is not None and (not root.is_dir() or root.is_symlink() or any(root.iterdir())):
    raise SystemExit("payload archive refused: destination must be an empty private directory")
try:
    with tarfile.open(archive, "r:*") as source:
        members = source.getmembers()
        seen = {}
        for member in members:
            name = member.name
            if member.isdir() and name.endswith("/"):
                name = name[:-1]
            parts = name.split("/")
            if (not name or name.startswith("/") or "\\" in name
                    or any(part in ("", ".", "..") for part in parts)
                    or parts[0] != "tightbeam"):
                raise ValueError("invalid path")
            reject_distribution_member(parts[-1])
            if name in seen:
                raise ValueError("duplicate path")
            if not (member.isdir() or member.isfile()):
                raise ValueError("link or special entry")
            if name == "tightbeam" and not member.isdir():
                raise ValueError("package root is not a directory")
            seen[name] = member
        if not members:
            raise ValueError("empty archive")
        for name in seen:
            for parent in pathlib.PurePosixPath(name).parents:
                if str(parent) != "." and str(parent) in seen and not seen[str(parent)].isdir():
                    raise ValueError("file used as ancestor")
        if inventory_only:
            sys.exit(0)
        # No archive-controlled writes occur until every header passes.
        for name, member in seen.items():
            target = root.joinpath(*name.split("/"))
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as incoming, target.open("xb") as output:
                    shutil.copyfileobj(incoming, output)
                target.chmod(member.mode & 0o777)
except (OSError, ValueError, tarfile.TarError) as error:
    raise SystemExit("payload archive refused: " + str(error))
