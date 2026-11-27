#!/usr/bin/env python3
"""Import and assemble only the declared Harklight people relay release members."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess


REPOSITORY = "https://github.com/clickety-clacks/harklight-tightbeam-pack"
TREE_PATH = "pack/relay"
SOURCE_RECORD = "SOURCE.json"
RELAY_MEMBERS = {
    "README.md": "100644",
    "addresses.py": "100644",
    "agent_cli.py": "100644",
    "config.example.json": "100644",
    "harklight-people-relay.service": "100644",
    "harklight-people-relay.timer": "100644",
    "harklight_agent.py": "100644",
    "outgoing.py": "100644",
    "projection.py": "100644",
    "relay.py": "100644",
    "relay_state.py": "100644",
    "tightbeam_people.py": "100644",
}


def git(checkout, *args):
    return subprocess.check_output(["git", "-C", str(checkout), *args])


def oid(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ValueError("expected a full 40-hex Git object ID")
    return value


def git_object_hash(kind, contents):
    header = f"{kind} {len(contents)}\0".encode()
    return hashlib.sha1(header + contents).hexdigest()


def relay_tree(files):
    entries = []
    for name, mode in sorted(RELAY_MEMBERS.items()):
        blob = git_object_hash("blob", files[name])
        entries.append(f"{mode} {name}\0".encode() + bytes.fromhex(blob))
    return git_object_hash("tree", b"".join(entries))


def write_members(root, files):
    root.mkdir(mode=0o755, parents=True)
    root.chmod(0o755)
    for name, contents in sorted(files.items()):
        path = root / name
        path.write_bytes(contents)
        path.chmod(int(RELAY_MEMBERS.get(name, "100644")[-3:], 8))


def import_tree(checkout, commit, tree, destination):
    commit, tree = oid(commit), oid(tree)
    if git(checkout, "rev-parse", f"{commit}:{TREE_PATH}").decode().strip() != tree:
        raise ValueError("pack/relay tree does not match the reviewed tree ID")
    entries = {}
    for entry in git(checkout, "ls-tree", "-z", tree).split(b"\0"):
        if entry:
            fields, name = entry.decode().split("\t", 1)
            mode, kind, blob = fields.split()
            if kind != "blob":
                raise ValueError(f"unexpected Git {kind} at {name}")
            entries[name] = (mode, blob)
    if {name: mode for name, (mode, _) in entries.items()} != RELAY_MEMBERS:
        raise ValueError("relay tree members or modes differ from the package allowlist")

    files = {name: git(checkout, "cat-file", "blob", blob)
             for name, (_, blob) in entries.items()}
    files["LICENSE"] = git(checkout, "show", f"{commit}:LICENSE")
    manifest = {
        "repository": REPOSITORY,
        "commit": commit,
        "tree_path": TREE_PATH,
        "tree": tree,
        "sha256": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()},
    }
    files[SOURCE_RECORD] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    write_members(destination, files)


def validated_members(root):
    if {path.name for path in root.iterdir()} != set(RELAY_MEMBERS) | {"LICENSE", SOURCE_RECORD}:
        raise ValueError("relay payload members differ from the package allowlist")
    files = {}
    for path in root.iterdir():
        actual = path.lstat().st_mode
        mode = int(RELAY_MEMBERS.get(path.name, "100644")[-3:], 8)
        if not stat.S_ISREG(actual) or stat.S_IMODE(actual) != mode:
            raise ValueError(f"relay member has an unexpected type or mode: {path.name}")
        files[path.name] = path.read_bytes()
    manifest = json.loads(files[SOURCE_RECORD])
    if manifest["repository"] != REPOSITORY or manifest["tree_path"] != TREE_PATH:
        raise ValueError("unexpected relay source repository or path")
    oid(manifest["commit"])
    if relay_tree(files) != oid(manifest["tree"]):
        raise ValueError("relay member bytes do not reconstruct the pinned Git tree")
    checksums = {name: hashlib.sha256(contents).hexdigest()
                 for name, contents in files.items() if name != SOURCE_RECORD}
    if checksums != manifest["sha256"]:
        raise ValueError("relay member SHA-256 checksums do not match the source record")
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    importer = commands.add_parser("import")
    importer.add_argument("checkout", type=Path)
    importer.add_argument("commit")
    importer.add_argument("tree")
    importer.add_argument("destination", type=Path)
    assembler = commands.add_parser("assemble")
    assembler.add_argument("source", type=Path)
    assembler.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "import":
            import_tree(args.checkout, args.commit, args.tree, args.destination)
        else:
            write_members(args.destination, validated_members(args.source))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"relay payload: {error}\n")


if __name__ == "__main__":
    main()
