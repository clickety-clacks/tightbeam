#!/usr/bin/env python3
"""Create and verify canonical release-candidate package proof."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

PLATFORMS = ("darwin-aarch64", "linux-x86_64")
SHA_RE = re.compile(r"[0-9a-f]{40}")
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
INPUT_KEYS = {
    "candidate_ref",
    "protected_base_sha",
    "repository",
    "reviewed_feature_shas",
    "schema",
    "source_sha",
}
PROOF_KEYS = INPUT_KEYS | {"packages", "run_id", "toolchains", "workflow_sha"}
EVIDENCE_KEYS = {"path", "platform", "sha256"}


class Refusal(ValueError):
    pass


def refuse(message: str) -> None:
    raise Refusal(message)


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def load_canonical(path: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        refuse(f"{path}: invalid JSON: {error}")
    if not isinstance(value, dict):
        refuse(f"{path}: root must be an object")
    if raw != canonical_bytes(value):
        refuse(f"{path}: bytes are not canonical JSON")
    return value


def exact_keys(value: dict[str, Any], expected: set[str], subject: str) -> None:
    if set(value) != expected:
        missing = sorted(expected - set(value))
        unknown = sorted(set(value) - expected)
        refuse(f"{subject}: wrong fields; missing={missing}, unknown={unknown}")


def exact_sha(value: Any, subject: str) -> str:
    if not isinstance(value, str) or SHA_RE.fullmatch(value) is None:
        refuse(f"{subject}: expected an exact lower-case 40-hex SHA")
    return value


def exact_digest(value: Any, subject: str) -> str:
    if not isinstance(value, str) or DIGEST_RE.fullmatch(value) is None:
        refuse(f"{subject}: expected an exact lower-case SHA-256")
    return value


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_input(value: dict[str, Any]) -> None:
    exact_keys(value, INPUT_KEYS, "candidate input")
    if value["schema"] != "tightbeam-release-candidate-input/v1":
        refuse("candidate input: wrong schema")
    if not isinstance(value["repository"], str) or not value["repository"]:
        refuse("candidate input: repository is required")
    if not isinstance(value["candidate_ref"], str) or not value["candidate_ref"].startswith(
        "refs/heads/release-candidate/"
    ):
        refuse("candidate input: candidate_ref must name release-candidate/*")
    base = exact_sha(value["protected_base_sha"], "candidate input protected_base_sha")
    source = exact_sha(value["source_sha"], "candidate input source_sha")
    features = value["reviewed_feature_shas"]
    if not isinstance(features, list) or not features:
        refuse("candidate input: reviewed_feature_shas must be non-empty")
    for index, feature in enumerate(features):
        exact_sha(feature, f"candidate input reviewed_feature_shas[{index}]")
    if len(features) != len(set(features)):
        refuse("candidate input: reviewed_feature_shas contains a duplicate")
    if source != features[-1]:
        refuse("candidate input: source_sha must equal the last reviewed feature SHA")
    if base == source:
        refuse("candidate input: protected base and source must differ")


def evidence_entries(root: Path, kind: str) -> list[dict[str, str]]:
    entries = []
    for platform in PLATFORMS:
        if kind == "packages":
            directory = root / "packages" / platform
            matches = sorted(directory.glob("tightbeam-*.tgz")) if directory.is_dir() else []
            if len(matches) != 1:
                refuse(f"evidence: expected exactly one {platform} package, found {len(matches)}")
            path = matches[0]
            if not path.name.endswith(f"-{platform}.tgz"):
                refuse(f"evidence: package name does not match platform {platform}")
        else:
            path = root / "toolchains" / f"{platform}.txt"
            if not path.is_file():
                refuse(f"evidence: missing {platform} toolchain record")
            contents = path.read_text()
            for marker in ("Erlang/OTP", "Elixir", "rustc"):
                if marker not in contents:
                    refuse(f"evidence: {platform} toolchain record lacks {marker}")
        entries.append(
            {
                "path": path.relative_to(root).as_posix(),
                "platform": platform,
                "sha256": file_digest(path),
            }
        )
    return entries


def create(args: argparse.Namespace) -> None:
    candidate = load_canonical(args.candidate_input)
    validate_input(candidate)
    workflow_sha = exact_sha(args.workflow_sha, "workflow_sha")
    if not args.run_id.isdigit():
        refuse("run_id must contain decimal digits only")
    proof = dict(candidate)
    proof["schema"] = "tightbeam-release-candidate-proof/v1"
    proof["workflow_sha"] = workflow_sha
    proof["run_id"] = args.run_id
    proof["packages"] = evidence_entries(args.evidence_root, "packages")
    proof["toolchains"] = evidence_entries(args.evidence_root, "toolchains")
    args.output.write_bytes(canonical_bytes(proof))


def git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode != 0:
        refuse(f"git {' '.join(arguments)} refused: {result.stderr.strip()}")
    return result.stdout.strip()


def verify_graph(value: dict[str, Any], root: Path) -> None:
    base = value["protected_base_sha"]
    source = value["source_sha"]
    git(root, "cat-file", "-e", f"{base}^{{commit}}")
    git(root, "cat-file", "-e", f"{source}^{{commit}}")
    git(root, "merge-base", "--is-ancestor", base, source)
    expected = git(root, "rev-list", "--reverse", "--topo-order", f"{base}..{source}").splitlines()
    if expected != value["reviewed_feature_shas"]:
        refuse("manifest: reviewed features do not equal the exact ordered Git range")


def verify_evidence(value: dict[str, Any], root: Path, kind: str) -> None:
    rows = value[kind]
    if not isinstance(rows, list) or len(rows) != len(PLATFORMS):
        refuse(f"manifest: {kind} must contain exactly both supported platforms")
    if [row.get("platform") for row in rows if isinstance(row, dict)] != list(PLATFORMS):
        refuse(f"manifest: {kind} platform order or membership is wrong")
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            refuse(f"manifest: {kind}[{index}] must be an object")
        exact_keys(row, EVIDENCE_KEYS, f"manifest {kind}[{index}]")
        expected_digest = exact_digest(row["sha256"], f"manifest {kind}[{index}] sha256")
        relative = Path(row["path"])
        if relative.is_absolute() or ".." in relative.parts:
            refuse(f"manifest: {kind}[{index}] path escapes the evidence root")
        path = root / relative
        if not path.is_file():
            refuse(f"manifest: missing evidence file {relative}")
        if file_digest(path) != expected_digest:
            refuse(f"manifest: hash mismatch for {relative}")
        if kind == "packages" and not path.name.endswith(f"-{row['platform']}.tgz"):
            refuse(f"manifest: package name does not match platform {row['platform']}")
        if kind == "toolchains":
            contents = path.read_text()
            for marker in ("Erlang/OTP", "Elixir", "rustc"):
                if marker not in contents:
                    refuse(f"manifest: {relative} lacks {marker}")


def verify(args: argparse.Namespace) -> None:
    value = load_canonical(args.manifest)
    exact_keys(value, PROOF_KEYS, "manifest")
    input_value = {key: value[key] for key in INPUT_KEYS}
    input_value["schema"] = "tightbeam-release-candidate-input/v1"
    validate_input(input_value)
    if value["schema"] != "tightbeam-release-candidate-proof/v1":
        refuse("manifest: wrong schema")
    exact_sha(value["workflow_sha"], "manifest workflow_sha")
    if not isinstance(value["run_id"], str) or not value["run_id"].isdigit():
        refuse("manifest: run_id must contain decimal digits only")
    expected = {
        "repository": args.expected_repository,
        "candidate_ref": args.expected_ref,
        "source_sha": args.expected_source_sha,
        "workflow_sha": args.expected_workflow_sha,
    }
    for field, wanted in expected.items():
        if value[field] != wanted:
            refuse(f"manifest: {field} mismatch; expected {wanted}, found {value[field]}")
    verify_graph(value, args.repository_root)
    verify_evidence(value, args.evidence_root, "packages")
    verify_evidence(value, args.evidence_root, "toolchains")


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser()
    commands = top.add_subparsers(dest="command", required=True)
    create_parser = commands.add_parser("create")
    create_parser.add_argument("--candidate-input", type=Path, required=True)
    create_parser.add_argument("--evidence-root", type=Path, required=True)
    create_parser.add_argument("--workflow-sha", required=True)
    create_parser.add_argument("--run-id", required=True)
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.set_defaults(run=create)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--manifest", type=Path, required=True)
    verify_parser.add_argument("--evidence-root", type=Path, required=True)
    verify_parser.add_argument("--repository-root", type=Path, required=True)
    verify_parser.add_argument("--expected-repository", required=True)
    verify_parser.add_argument("--expected-ref", required=True)
    verify_parser.add_argument("--expected-source-sha", required=True)
    verify_parser.add_argument("--expected-workflow-sha", required=True)
    verify_parser.set_defaults(run=verify)
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        args.run(args)
    except (OSError, Refusal) as error:
        print(f"release candidate manifest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
