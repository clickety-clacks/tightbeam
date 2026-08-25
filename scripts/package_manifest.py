#!/usr/bin/env python3
"""Create and verify the canonical manifest for an assembled package payload."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any

SCHEMA = "tightbeam-payload-manifest/v1"
EVIDENCE_SCHEMA = "tightbeam-verification-evidence/v1"
ROOT_NAME = "tightbeam"


class Refusal(ValueError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def load_canonical(path: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise Refusal(f"{path}: invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise Refusal(f"{path}: root must be an object")
    if raw != canonical_bytes(value):
        raise Refusal(f"{path}: bytes are not canonical JSON")
    return value


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def entry(path: str, kind: str, mode: int, size: int, digest: str) -> dict[str, Any]:
    return {
        "path": path,
        "type": kind,
        "mode": format(mode, "04o"),
        "size": size,
        "sha256": digest,
    }


def bytes_entry(path: str, file_path: Path, mode: int) -> dict[str, Any]:
    return entry(path, "file", mode, file_path.stat().st_size, digest_file(file_path))


def root_manifest(root: Path) -> dict[str, Any]:
    if not root.is_dir():
        raise Refusal(f"payload root is not a directory: {root}")

    entries: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        info = path.lstat()
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISREG(info.st_mode):
            entries.append(bytes_entry(relative, path, mode))
        elif stat.S_ISDIR(info.st_mode):
            entries.append(entry(relative, "directory", mode, 0, digest_bytes(b"")))
        elif stat.S_ISLNK(info.st_mode):
            target = os.readlink(path).encode()
            entries.append(entry(relative, "symlink", mode, len(target), digest_bytes(target)))
        else:
            raise Refusal(f"unsupported payload member type: {relative}")

    return {"schema": SCHEMA, "root": ROOT_NAME, "entries": entries}


def safe_member_path(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise Refusal(f"archive member escapes payload root: {name}")
    return path


def archive_entry(member: tarfile.TarInfo, archive: tarfile.TarFile) -> dict[str, Any] | None:
    path = safe_member_path(member.name)
    if path == PurePosixPath(ROOT_NAME):
        if not member.isdir():
            raise Refusal("archive root is not a directory")
        return None
    if not path.parts or path.parts[0] != ROOT_NAME:
        raise Refusal(f"archive member is outside {ROOT_NAME}: {member.name}")
    relative = PurePosixPath(*path.parts[1:]).as_posix()
    mode = member.mode & 0o7777
    if member.isfile():
        stream = archive.extractfile(member)
        if stream is None:
            raise Refusal(f"archive member has no data: {member.name}")
        data = stream.read()
        return entry(relative, "file", mode, len(data), digest_bytes(data))
    if member.isdir():
        return entry(relative, "directory", mode, 0, digest_bytes(b""))
    if member.issym():
        target = member.linkname.encode()
        return entry(relative, "symlink", mode, len(target), digest_bytes(target))
    raise Refusal(f"unsupported archive member type: {member.name}")


def archive_manifest(artifact: Path) -> dict[str, Any]:
    try:
        archive = tarfile.open(artifact, "r:gz")
    except (OSError, tarfile.TarError) as error:
        raise Refusal(f"cannot read package archive {artifact}: {error}") from error
    with archive:
        entries = []
        seen: set[str] = set()
        root_seen = False
        for member in archive.getmembers():
            if safe_member_path(member.name) == PurePosixPath(ROOT_NAME):
                if root_seen:
                    raise Refusal(f"duplicate archive member: {ROOT_NAME}")
                root_seen = True
            candidate = archive_entry(member, archive)
            if candidate is None:
                continue
            path = candidate["path"]
            if path in seen:
                raise Refusal(f"duplicate archive member: {path}")
            seen.add(path)
            entries.append(candidate)
        if not root_seen:
            raise Refusal(f"archive has no {ROOT_NAME} root")
    entries.sort(key=lambda value: value["path"])
    return {"schema": SCHEMA, "root": ROOT_NAME, "entries": entries}


def write_manifest(value: dict[str, Any], output: Path) -> None:
    output.write_bytes(canonical_bytes(value))


def create(args: argparse.Namespace) -> None:
    if bool(args.root) == bool(args.artifact):
        raise Refusal("exactly one of --root or --artifact is required")
    value = root_manifest(args.root) if args.root else archive_manifest(args.artifact)
    write_manifest(value, args.output)


def verify(args: argparse.Namespace) -> None:
    value = load_canonical(args.manifest)
    if value.get("schema") != SCHEMA or value.get("root") != ROOT_NAME:
        raise Refusal(f"{args.manifest}: wrong payload manifest schema")
    expected = archive_manifest(args.artifact)
    if value != expected:
        raise Refusal(f"{args.artifact}: payload manifest does not match archive bytes")


def evidence(args: argparse.Namespace) -> None:
    manifest = load_canonical(args.manifest)
    if manifest.get("schema") != SCHEMA:
        raise Refusal(f"{args.manifest}: wrong payload manifest schema")
    value = {
        "artifact_sha256": digest_file(args.artifact),
        "checks": ["version-smoke", "payload-manifest"],
        "package_version": args.version,
        "payload_manifest_sha256": digest_file(args.manifest),
        "schema": EVIDENCE_SCHEMA,
    }
    write_manifest(value, args.output)


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser()
    commands = top.add_subparsers(dest="command", required=True)

    create_parser = commands.add_parser("create")
    create_parser.add_argument("--root", type=Path)
    create_parser.add_argument("--artifact", type=Path)
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.set_defaults(run=create)

    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--artifact", type=Path, required=True)
    verify_parser.add_argument("--manifest", type=Path, required=True)
    verify_parser.set_defaults(run=verify)

    evidence_parser = commands.add_parser("evidence")
    evidence_parser.add_argument("--artifact", type=Path, required=True)
    evidence_parser.add_argument("--manifest", type=Path, required=True)
    evidence_parser.add_argument("--version", required=True)
    evidence_parser.add_argument("--output", type=Path, required=True)
    evidence_parser.set_defaults(run=evidence)
    return top


def main() -> int:
    try:
        args = parser().parse_args()
        args.run(args)
    except (OSError, Refusal, tarfile.TarError) as error:
        print(f"package manifest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
