#!/bin/sh
set -eu
ARTIFACT=${1:?usage: verify-payload.sh artifact.tgz}
TEMP_DIR=$(mktemp -d)
TEMP_DIR=$(cd "$TEMP_DIR" && pwd -P)
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM
python3 "$(dirname "$0")/extract-payload.py" "$ARTIFACT" "$TEMP_DIR"
elixir "$(dirname "$0")/payload-manifest.exs" verify "$TEMP_DIR/tightbeam"
