#!/usr/bin/env python3
"""Keep the shipped external-agent skills honest for this release.

Each skill that `tightbeam skill install` ships (the include_str! list in
cli/src/skills.rs) must:
  - say it was written for the version in cli/Cargo.toml, the release version;
  - name no Tightbeam record identifier (a prefix, `_` or `-`, then 8+ hex digits);
  - name no term from an optional deny-list kept outside this repository.

The deny-list is read from the file named by TIGHTBEAM_SKILL_DENYLIST, one term per
line (blank lines and lines starting with # are ignored). Matching is
case-insensitive on whole words. Without the variable this check is skipped.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHIPPED_SKILL = re.compile(r'include_str!\("\.\./\.\./priv/skills/([a-z0-9-]+)/SKILL\.md"\)')
STAMP = re.compile(r"^Written for Tightbeam (\S+?)\.?(?:\s|$)", re.M)
VERSION = re.compile(r'^version\s*=\s*"([^"]+)"$', re.M)
RECORD_ID = re.compile(r"\b[a-z]{1,6}[_-][0-9a-f]{8,}\b")


def release_version(root: pathlib.Path) -> str:
    match = VERSION.search((root / "cli/Cargo.toml").read_text(encoding="utf-8"))
    if not match:
        raise SystemExit("external skills: cli/Cargo.toml has no version")
    return match.group(1)


def shipped(root: pathlib.Path) -> list[str]:
    names = SHIPPED_SKILL.findall((root / "cli/src/skills.rs").read_text(encoding="utf-8"))
    if not names:
        raise SystemExit("external skills: cli/src/skills.rs ships no skills")
    return names


def deny_terms() -> list[str]:
    path = os.environ.get("TIGHTBEAM_SKILL_DENYLIST")
    if not path:
        return []
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    return [line.strip() for line in lines if line.strip() and not line.startswith("#")]


def problems(root: pathlib.Path, names: list[str], version: str, terms: list[str]):
    for name in names:
        relative = f"priv/skills/{name}/SKILL.md"
        path = root / relative
        if not path.is_file():
            yield f"{relative}: missing"
            continue
        text = path.read_text(encoding="utf-8")
        if not text.startswith(f"---\nname: {name}\n"):
            yield f"{relative}: frontmatter must open with name: {name}"
        stamp = STAMP.search(text)
        if not stamp:
            yield f"{relative}: no 'Written for Tightbeam <version>.' line"
        elif stamp.group(1) != version:
            yield (
                f"{relative}: written for {stamp.group(1)} but this release is {version}; "
                "re-check the skill against `tightbeam --help` and update its stamp"
            )
        for number, line in enumerate(text.splitlines(), 1):
            for match in RECORD_ID.finditer(line):
                yield f"{relative}:{number}: record identifier {match.group()}"
            for term in terms:
                if re.search(rf"\b{re.escape(term)}\b", line, re.I):
                    yield f"{relative}:{number}: deny-listed term"


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT
    version = release_version(root)
    names = shipped(root)
    found = list(problems(root, names, version, deny_terms()))
    for problem in found:
        print(f"external skills: {problem}", file=sys.stderr)
    if found:
        print(f"external skills: refused {len(found)} finding(s)", file=sys.stderr)
        return 1
    print(f"external skills: {len(names)} skill(s) written for {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
