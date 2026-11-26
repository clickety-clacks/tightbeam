#!/bin/sh
set -eu

archive=${1:?usage: verify-setup-build.sh ARCHIVE COMMIT [TAG]}
commit=${2:?usage: verify-setup-build.sh ARCHIVE COMMIT [TAG]}
tag=${3:-}

if ! identity=$(tar -xOf "$archive" tightbeam/setup-build.json); then
  echo "release: $archive is missing tightbeam/setup-build.json" >&2
  exit 1
fi

if ! printf '%s\n' "$identity" | jq -e --slurp --arg commit "$commit" --arg tag "$tag" '
  length == 1 and .[0].commit == $commit and
  (.[0].tag | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+[0-9]+$")) and
  ($tag == "" or .[0].tag == $tag)
' >/dev/null; then
  echo "release: $archive has invalid setup build identity for $commit ${tag}" >&2
  exit 1
fi
