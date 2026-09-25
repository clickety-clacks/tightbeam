#!/usr/bin/env python3
"""Reject a commit that removes a public rule fact from Tightbeam.Rules."""

import re
import subprocess
import sys
from pathlib import Path


SOURCE = Path("lib/tightbeam/rules.ex")
COMPATIBILITY_BASELINE = "6c13efcbe9e1ae247b8aa7e91a374015c74dc947"
LAST_SHIPPED_SOURCE = "e28880d6a2980c4ca5a7a983a707f83d504da960"
# This fact existed only in unshipped 0.1.9 candidates. It encoded engineering
# role policy in neutral runtime and was withdrawn before the 0.1.9 release.
UNSHIPPED_WITHDRAWN_FACTS = {
    "assign.admission_context": "27f74c1a2353cdee7ded640b8142ea98bfbae0cd^"
}
FACTS = re.compile(r'@facts %\{\n(.*?)\n  \}', re.DOTALL)
FACT_NAME = re.compile(r'^\s*"([^"]+)"\s*=>', re.MULTILINE)


def fact_names(source: str) -> set[str]:
    match = FACTS.search(source)
    if match is None:
        raise ValueError("could not find Tightbeam.Rules @facts registry")
    return set(FACT_NAME.findall(match.group(1)))


def history_refs() -> list[str]:
    shallow = subprocess.check_output(
        ["git", "rev-parse", "--is-shallow-repository"],
        text=True,
        stderr=subprocess.PIPE,
    ).strip()
    if shallow != "false":
        raise ValueError("repository history is shallow")

    subprocess.check_call(
        ["git", "merge-base", "--is-ancestor", COMPATIBILITY_BASELINE, "HEAD"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    refs = subprocess.check_output(
        [
            "git",
            "rev-list",
            "--full-history",
            f"{COMPATIBILITY_BASELINE}^..HEAD",
            "--",
            str(SOURCE),
        ],
        text=True,
        stderr=subprocess.PIPE,
    ).splitlines()
    if COMPATIBILITY_BASELINE not in refs:
        raise ValueError("compatibility baseline is not in the rule-fact history")
    return refs


def source_at(ref: str) -> str:
    return subprocess.check_output(
        ["git", "show", f"{ref}:{SOURCE}"], text=True, stderr=subprocess.PIPE
    )


def ancestor_of(ref: str, ancestor_tip: str) -> bool:
    return subprocess.run(
        ["git", "merge-base", "--is-ancestor", ref, ancestor_tip],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    ).returncode == 0


def main() -> int:
    try:
        history = history_refs()
        historical_facts = {ref: fact_names(source_at(ref)) for ref in history}
        previous = set().union(*historical_facts.values())
    except (subprocess.CalledProcessError, ValueError) as error:
        print(
            f"public rule-fact compatibility: cannot inspect complete history: {error}",
            file=sys.stderr,
        )
        return 1

    current = fact_names(SOURCE.read_text())
    shipped = fact_names(source_at(LAST_SHIPPED_SOURCE))
    withdrawn = {
        fact
        for fact, withdrawal_parent in UNSHIPPED_WITHDRAWN_FACTS.items()
        if fact not in shipped
        and all(
            ancestor_of(ref, withdrawal_parent)
            for ref, facts in historical_facts.items()
            if fact in facts
        )
    }
    removed = sorted(previous - current - withdrawn)
    if removed:
        print("public rule facts cannot be removed:", *removed, sep="\n", file=sys.stderr)
        return 1

    print("public rule-fact compatibility: pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
