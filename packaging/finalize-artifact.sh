#!/bin/sh
# Publish only an artifact that has passed the extracted-byte version proof.
# TEMP and FINAL are siblings in assemble.sh, so mv is an atomic rename.
set -eu

TEMP=${1:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version>}
FINAL=${2:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version>}
EXPECTED=${3:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version>}

sh "$(dirname "$0")/version-smoke.sh" "$TEMP" "$EXPECTED"
mv "$TEMP" "$FINAL"
