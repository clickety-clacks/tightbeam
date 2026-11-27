#!/usr/bin/env python3
"""Import and assemble only the declared Harklight people relay release members."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import tarfile


REPOSITORY = "https://github.com/clickety-clacks/harklight-tightbeam-pack"
TREE_PATH = "pack/relay"
SOURCE_RECORD = "SOURCE.json"
RUNTIME_ROOT = "tightbeam/optional/harklight-people-relay"
ARCHIVE_ROOT = RUNTIME_ROOT + "/source"
RUNTIME_DOC = "README.md"
UNIT = "harklight-people-relay-watch.service"
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
        path.chmod(member_mode(name))


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


def member_mode(name):
    return int(RELAY_MEMBERS.get(name, "100644")[-3:], 8)


def read_members(root):
    files = {}
    for path in root.iterdir():
        actual = path.lstat().st_mode
        mode = member_mode(path.name)
        if not stat.S_ISREG(actual) or stat.S_IMODE(actual) != mode:
            raise ValueError(f"relay member has an unexpected type or mode: {path.name}")
        files[path.name] = path.read_bytes()
    return files


def validate_members(files):
    if set(files) != set(RELAY_MEMBERS) | {"LICENSE", SOURCE_RECORD}:
        raise ValueError("relay payload members differ from the package allowlist")
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
    return manifest


def verify_archive(path, operating_system):
    files = {}
    support = {
        RUNTIME_ROOT: (None, 0o755),
        f"{RUNTIME_ROOT}/{RUNTIME_DOC}": (RUNTIME_DOC, 0o644),
    }
    if operating_system == "linux":
        support[f"{RUNTIME_ROOT}/systemd"] = (None, 0o755)
        support[f"{RUNTIME_ROOT}/systemd/{UNIT}"] = (UNIT, 0o644)
    found_support = set()
    directory = False
    with tarfile.open(path, "r:gz") as archive:
        for member in archive:
            if member.name in support:
                name, mode = support[member.name]
                if member.name in found_support or member.mode != mode:
                    raise ValueError(f"unexpected relay archive entry: {member.name}")
                found_support.add(member.name)
                if name is None:
                    if not member.isdir():
                        raise ValueError(f"expected a directory: {member.name}")
                else:
                    if not member.isfile():
                        raise ValueError(f"expected a regular file: {member.name}")
                    source = Path(__file__).with_name("relay-runtime") / name
                    with archive.extractfile(member) as data:
                        content = data.read()
                    if content != source.read_bytes():
                        raise ValueError(f"relay archive bytes do not match source: {member.name}")
                    print(f"{mode:04o} {hashlib.sha256(content).hexdigest()} {member.name}")
            elif member.name == ARCHIVE_ROOT:
                if directory or not member.isdir() or member.mode != 0o755:
                    raise ValueError("relay archive root is duplicated or has an unexpected type or mode")
                directory = True
            elif member.name.startswith(ARCHIVE_ROOT + "/"):
                name = member.name[len(ARCHIVE_ROOT) + 1:]
                if name in files or not member.isfile() or member.mode != member_mode(name):
                    raise ValueError(f"unexpected relay archive entry: {member.name}")
                with archive.extractfile(member) as data:
                    files[name] = data.read()
            elif member.name.startswith(RUNTIME_ROOT + "/"):
                raise ValueError(f"unexpected member under the relay runtime root: {member.name}")
    if not directory or found_support != set(support):
        raise ValueError("relay archive is missing a source or runtime member")
    manifest = validate_members(files)
    print(f"relay payload: commit={manifest['commit']} tree={manifest['tree']}")
    for name in sorted(files):
        print(f"{member_mode(name):04o} {hashlib.sha256(files[name]).hexdigest()} {ARCHIVE_ROOT}/{name}")


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
    verifier = commands.add_parser("verify-archive")
    verifier.add_argument("archive", type=Path)
    verifier.add_argument("platform", choices=["linux", "darwin"])
    args = parser.parse_args()
    try:
        if args.command == "import":
            import_tree(args.checkout, args.commit, args.tree, args.destination)
        elif args.command == "assemble":
            files = read_members(args.source)
            validate_members(files)
            write_members(args.destination, files)
        else:
            verify_archive(args.archive, args.platform)
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"relay payload: {error}\n")


if __name__ == "__main__":
    main()
