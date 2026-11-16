#!/usr/bin/env python3
"""Create and verify the selector-ready sidecar artifact for a main candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

REPOSITORY = "clickety-clacks/tightbeam"
PLATFORMS = ("darwin-aarch64", "linux-x86_64")
SHA_RE = re.compile(r"[0-9a-f]{40}")
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
TAG_RE = re.compile(r"v([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)")
PROOF_KEYS = {
    "candidate_ref",
    "packages",
    "protected_base_sha",
    "repository",
    "reviewed_feature_shas",
    "run_id",
    "schema",
    "source_sha",
    "toolchains",
    "workflow_sha",
}


class Refusal(ValueError):
    pass


def refuse(message: str) -> None:
    raise Refusal(message)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def read_json(path: Path, subject: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_bytes())
    except (OSError, json.JSONDecodeError) as error:
        refuse(f"{subject}: cannot read JSON: {error}")
    if not isinstance(value, dict):
        refuse(f"{subject}: root must be an object")
    return value


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode != 0:
        refuse(f"git {' '.join(args)} refused: {result.stderr.strip()}")
    return result.stdout.strip()


def expected_values(args: argparse.Namespace) -> dict[str, str]:
    if args.repository != REPOSITORY:
        refuse(f"unsupported candidate repository {args.repository}")
    for name, value in (("source SHA", args.source_sha), ("workflow SHA", args.workflow_sha)):
        if SHA_RE.fullmatch(value) is None:
            refuse(f"{name} must be exact lower-case 40-hex")
    if args.source_sha != args.workflow_sha:
        refuse("main candidate workflow SHA must equal the candidate source SHA")
    if not args.run_id.isdigit():
        refuse("candidate run ID must contain decimal digits only")
    match = TAG_RE.fullmatch(args.release_tag)
    if match is None:
        refuse("release tag must be exactly v<major>.<minor>.<patch>+<build>")
    if match.group(1) != args.version:
        refuse("release tag version does not match the candidate package version")
    build = git(args.repository_root, "rev-list", "--count", args.source_sha)
    if match.group(2) != build:
        refuse("release tag build number does not match the candidate commit")
    if git(args.repository_root, "rev-parse", "HEAD") != args.source_sha:
        refuse("candidate checkout does not match the exact source SHA")
    server_url = args.server_url.rstrip("/")
    if not server_url.startswith("https://"):
        refuse("workflow server URL must use HTTPS")
    return {
        "repository": args.repository,
        "run_id": args.run_id,
        "source_sha": args.source_sha,
        "workflow_sha": args.workflow_sha,
        "release_tag": args.release_tag,
        "version": args.version,
        "workflow_url": f"{server_url}/{args.repository}/actions/runs/{args.run_id}",
    }


def proof_packages(proof: dict[str, Any], evidence_root: Path, expected: dict[str, str]) -> dict[str, Path]:
    if set(proof) != PROOF_KEYS:
        refuse("candidate proof has an unexpected schema")
    if proof["schema"] != "tightbeam-release-candidate-proof/v1":
        refuse("candidate proof has the wrong schema")
    if proof["repository"] != expected["repository"]:
        refuse("candidate proof repository mismatch")
    if proof["candidate_ref"] != "refs/heads/main":
        refuse("selector staging is available only for main candidates")
    for field in ("source_sha", "workflow_sha", "run_id"):
        if str(proof[field]) != expected[field]:
            refuse(f"candidate proof {field} mismatch")
    if proof["workflow_sha"] != proof["source_sha"]:
        refuse("candidate proof workflow SHA does not match its source SHA")
    rows = proof["packages"]
    if not isinstance(rows, list) or len(rows) != len(PLATFORMS):
        refuse("candidate proof must name both platform packages")
    packages: dict[str, Path] = {}
    for row, platform in zip(rows, PLATFORMS, strict=True):
        if not isinstance(row, dict) or set(row) != {"path", "platform", "sha256"}:
            refuse("candidate proof package row has the wrong fields")
        relative = Path(row["path"])
        if row["platform"] != platform or relative.is_absolute() or ".." in relative.parts:
            refuse(f"candidate proof package path does not match {platform}")
        if relative.parent != Path("packages") / platform:
            refuse(f"candidate proof package is outside the {platform} evidence directory")
        if relative.name != f"tightbeam-{expected['version']}-{platform}.tgz":
            refuse(f"candidate proof package name does not match {platform}")
        if DIGEST_RE.fullmatch(row["sha256"]) is None:
            refuse(f"candidate proof package digest is invalid for {platform}")
        path = evidence_root / relative
        if not path.is_file() or digest(path) != row["sha256"]:
            refuse(f"candidate proof package is missing or has changed: {relative}")
        packages[platform] = path
    return packages


def provenance_value(expected: dict[str, str], proof_sha: str, package_names: list[str]) -> dict[str, Any]:
    return {
        "format": "tightbeam-release-candidate-provenance/v1",
        "repository": expected["repository"],
        "tag": expected["release_tag"],
        "commit": expected["source_sha"],
        "workflow": expected["workflow_url"],
        "candidate": {
            "run_id": expected["run_id"],
            "workflow": expected["workflow_url"],
            "workflow_sha": expected["workflow_sha"],
            "proof_manifest_sha256": proof_sha,
        },
        "assets": package_names + ["release-candidate-manifest.json"],
        "checksums": "SHA256SUMS",
    }


def expected_stage_files(stage_root: Path, proof_path: Path, packages: dict[str, Path], expected: dict[str, str]) -> dict[str, str]:
    if not proof_path.is_file():
        refuse("candidate proof manifest is missing")
    proof_sha = digest(proof_path)
    names = [
        f"tightbeam-{expected['version']}-{platform}-{expected['source_sha'][:7]}.tgz"
        for platform in PLATFORMS
    ]
    provenance = provenance_value(expected, proof_sha, names)
    expected_files: dict[str, str] = {}
    for platform, name in zip(PLATFORMS, names, strict=True):
        package_path = stage_root / name
        if not package_path.is_file() or digest(package_path) != digest(packages[platform]):
            refuse(f"staged candidate package differs from its proof bytes: {platform}")
        expected_files[name] = digest(package_path)
    staged_manifest = stage_root / "release-candidate-manifest.json"
    if not staged_manifest.is_file() or staged_manifest.read_bytes() != proof_path.read_bytes():
        refuse("staged candidate proof manifest differs from the verified proof")
    expected_files["release-candidate-manifest.json"] = proof_sha
    provenance_path = stage_root / "release-provenance.json"
    if not provenance_path.is_file():
        refuse("candidate release provenance is missing")
    if read_json(provenance_path, "candidate release provenance") != provenance:
        refuse("candidate release provenance does not bind the exact run, source, tag, and assets")
    sums_path = stage_root / "SHA256SUMS"
    if not sums_path.is_file():
        refuse("candidate SHA256SUMS is missing")
    sum_rows = "".join(f"{sha}  {name}\n" for name, sha in sorted(expected_files.items()))
    if sums_path.read_text() != sum_rows:
        refuse("candidate SHA256SUMS does not exactly bind the staged packages and proof")
    expected_names = set(expected_files) | {"release-provenance.json", "SHA256SUMS"}
    if {path.name for path in stage_root.iterdir()} != expected_names:
        refuse("candidate staging artifact contains unexpected or missing files")
    return expected_files


def create(args: argparse.Namespace, expected: dict[str, str], proof_path: Path,
           packages: dict[str, Path]) -> None:
    stage_root = args.stage_root
    if stage_root.exists():
        refuse("candidate staging output already exists")
    stage_root.mkdir(parents=True)
    names = []
    try:
        for platform in PLATFORMS:
            name = f"tightbeam-{expected['version']}-{platform}-{expected['source_sha'][:7]}.tgz"
            names.append(name)
            shutil.copyfile(packages[platform], stage_root / name)
        shutil.copyfile(proof_path, stage_root / "release-candidate-manifest.json")
        proof_sha = digest(proof_path)
        provenance = provenance_value(expected, proof_sha, names)
        (stage_root / "release-provenance.json").write_text(
            json.dumps(provenance, indent=2, sort_keys=True) + "\n"
        )
        sums_names = sorted(names + ["release-candidate-manifest.json"])
        (stage_root / "SHA256SUMS").write_text(
            "".join(f"{digest(stage_root / name)}  {name}\n" for name in sums_names)
        )
        expected_stage_files(stage_root, proof_path, packages, expected)
    except Exception:
        shutil.rmtree(stage_root, ignore_errors=True)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("create", "verify"))
    parser.add_argument("--proof-manifest", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--stage-root", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--server-url", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--workflow-sha", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--version", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        expected = expected_values(args)
        proof_path = args.proof_manifest
        proof = read_json(proof_path, "candidate proof")
        if proof_path.read_bytes() != canonical_bytes(proof):
            refuse("candidate proof is not canonical JSON")
        packages = proof_packages(proof, args.evidence_root, expected)
        if args.command == "create":
            create(args, expected, proof_path, packages)
        else:
            expected_stage_files(args.stage_root, proof_path, packages, expected)
        return 0
    except (OSError, Refusal, subprocess.SubprocessError) as error:
        print(f"release candidate stage: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
