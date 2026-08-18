#!/usr/bin/env python3
"""Refuse internal identifiers in files shipped from priv/."""

from __future__ import annotations

import hashlib
import ipaddress
import pathlib
import re
import sys


# SHA-256 of case-folded private user, host, device, volume, and service names.
# Hashes keep the gate from publishing the identifiers it is designed to catch.
FORBIDDEN = {
    "048d5aee7bb947356c6861e7aba8df55e1be7a775076358baaf633d25d1c5d18",
    "0cb87f727f31e5f5a59cca8a10c8f9b55622be05305d4e7e92c334f5911e1034",
    "2c8c4f00dee0bb25cb5cda2ef243456e7fa9a11dbb37a24b159d3c35177a0393",
    "382dd7e80c76f59c786adfbd4426b66648fdc7de335ca179ce25e80935f140e2",
    "403f0ec467bba08f05e84926737b7fa31fd309d75dccb093b2587a9db1c8d6e2",
    "425f582e5c8a6b5a980f2cfe36b5f057b8052c7ba70ff2c9802c8f5ccf2178af",
    "44eb92b46360c22af3395633b6e3014a30afa97b02305b385c51d3feebceda9c",
    "64b4d0f47c93ce23d157e68a58767356283dc9b63c459d45d0e0e39b3a64b9b9",
    "833dc869548f1c4cf789a9fed733def2aae92697070cb31066b883ea6f91d4aa",
    "8b3d8d8d557b66d3a2524117171e1ad4cb6affb18b29f5ef2196755736d649ef",
    "b6ff9914366deb5d4d4a43d7d44c85ec462977d28600694816168ff707ade897",
    "c0d93ea09e20eb4c5ca5b8f26dead01bd67c5599fadc8ceb44ba7e24d48722fc",
    "c6c2307ac025abfed680cb646bc38ca3c3d6e02662a0f2faa143dcff22268a49",
    "c9bc5884fe86a6255d97633cb65e61d4a73f7eca69206fdfdc692d5bc6c6ec67",
    "d0c1e3958b8136aa94d17957e774866b53a2e43742a1e0dae40da3bd5256b4ff",
    "d289d6432069e4ae4b4a8efe76328d3fbbc2c413cfc585cde81fa98704667e08",
    "dffe7673c9f2ac9e462c591a5cd721828919e33945bd836f9fc9216d0a050540",
    "f1ce44e098a1ff50a85bc0920c9e43773ab91cb3cff9483e4e240f1c8fc37266",
    "fe05771a3d1c86c1f2849cb099d8f5377f65e461ba999dbacf8337cdd501743e",
}

WORD = re.compile(r"[a-z0-9]+", re.IGNORECASE)
IPV4 = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(cidr)
    for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10")
)


def digest(token: str) -> str:
    return hashlib.sha256(token.casefold().encode()).hexdigest()


def findings(label: str, text: str):
    for line_number, line in enumerate(text.splitlines(), 1):
        for match in WORD.finditer(line):
            token_hash = digest(match.group())
            if token_hash in FORBIDDEN:
                yield f"{label}:{line_number}: internal identifier ({token_hash[:12]})"
        for match in IPV4.finditer(line):
            try:
                address = ipaddress.ip_address(match.group())
            except ValueError:
                continue
            if any(address in network for network in PRIVATE_NETWORKS):
                yield f"{label}:{line_number}: private network address"


def main() -> int:
    root = pathlib.Path("priv")
    problems = list(findings("priv path", root.as_posix()))

    for path in sorted(root.rglob("*")):
        relative = path.as_posix()
        problems.extend(findings("priv path", relative))
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        problems.extend(findings(relative, text))

    if problems:
        for problem in problems:
            print(f"shipped privacy: {problem}", file=sys.stderr)
        print(f"shipped privacy: refused {len(problems)} finding(s)", file=sys.stderr)
        return 1

    print("shipped privacy: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
