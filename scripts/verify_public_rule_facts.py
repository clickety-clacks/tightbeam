#!/usr/bin/env python3
"""Reject a commit that removes a public rule fact from Tightbeam.Rules."""

import re
import subprocess
import sys
from pathlib import Path


SOURCE = Path("lib/tightbeam/rules.ex")
FACTS = re.compile(r'@facts %\{\n(.*?)\n  \}', re.DOTALL)
FACT_NAME = re.compile(r'^\s*"([^"]+)"\s*=>', re.MULTILINE)


def fact_names(source: str) -> set[str]:
    match = FACTS.search(source)
    if match is None:
        raise ValueError("could not find Tightbeam.Rules @facts registry")
    return set(FACT_NAME.findall(match.group(1)))


def parent_refs() -> list[str]:
    line = subprocess.check_output(
        ["git", "rev-list", "--parents", "-n", "1", "HEAD"],
        text=True,
        stderr=subprocess.PIPE,
    )
    return line.split()[1:]


def source_at(ref: str) -> str:
    return subprocess.check_output(
        ["git", "show", f"{ref}:{SOURCE}"], text=True, stderr=subprocess.PIPE
    )


def main() -> int:
    try:
        parents = parent_refs()
    except subprocess.CalledProcessError as error:
        print(f"public rule-fact compatibility: cannot inspect HEAD: {error}", file=sys.stderr)
        return 1

    if not parents:
        print("public rule-fact compatibility: no parent commit to compare")
        return 0

    try:
        previous = set().union(*(fact_names(source_at(parent)) for parent in parents))
    except (subprocess.CalledProcessError, ValueError) as error:
        print(f"public rule-fact compatibility: cannot inspect every parent: {error}", file=sys.stderr)
        return 1

    current = fact_names(SOURCE.read_text())
    removed = sorted(previous - current)
    if removed:
        print("public rule facts cannot be removed:", *removed, sep="\n", file=sys.stderr)
        return 1

    print("public rule-fact compatibility: pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
