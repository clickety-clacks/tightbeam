#!/bin/sh
# Refuse package archives that carry macOS host metadata instead of product bytes.
set -eu

ARTIFACT=${1:?usage: purity-check.sh <artifact.tgz>}

python3 - "$ARTIFACT" <<'PY'
import pathlib
import sys
import tarfile

artifact = sys.argv[1]
findings = []
member_count = 0


def forbidden_header(key):
    normalized = key.lower()
    return (
        normalized.startswith("libarchive.xattr.")
        or normalized.startswith("schily.xattr.")
        or normalized.startswith("schily.acl.")
        or normalized == "schily.fflags"
    )


def inspect_headers(headers, owner):
    for key in sorted(headers):
        if forbidden_header(key):
            findings.append(f"forbidden archive metadata header {key} on {owner}")


try:
    with tarfile.open(artifact, "r:*") as archive:
        inspect_headers(archive.pax_headers, "archive")

        for member in archive:
            member_count += 1
            path_parts = pathlib.PurePosixPath(member.name).parts
            if any(part.startswith("._") for part in path_parts):
                findings.append(f"forbidden AppleDouble entry: {member.name}")
            inspect_headers(member.pax_headers, member.name)
except (OSError, tarfile.TarError) as error:
    print(f"package purity: cannot inspect {artifact}: {error}", file=sys.stderr)
    sys.exit(1)

if findings:
    for finding in findings:
        print(f"package purity: {finding}", file=sys.stderr)
    print(
        f"package purity: refused {artifact}: {len(findings)} forbidden metadata record(s)",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"package purity: clean ({member_count} entries, no host metadata)")
PY
