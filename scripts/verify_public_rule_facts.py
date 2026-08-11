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


def parent_source() -> str:
    return subprocess.check_output(
        ["git", "show", f"HEAD^:{SOURCE}"], text=True, stderr=subprocess.PIPE
    )


def main() -> int:
    try:
        previous = fact_names(parent_source())
    except subprocess.CalledProcessError:
        print("public rule-fact compatibility: no parent commit to compare")
        return 0

    current = fact_names(SOURCE.read_text())
    removed = sorted(previous - current)
    if removed:
        print("public rule facts cannot be removed:", *removed, sep="\n", file=sys.stderr)
        return 1

    print("public rule-fact compatibility: pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
