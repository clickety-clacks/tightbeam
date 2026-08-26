#!/bin/sh
# Publish only an artifact that has passed the extracted-byte version proof.
# TEMP and FINAL are siblings in assemble.sh, so mv is an atomic rename.
set -eu

TEMP=${1:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version> <temporary-manifest> <final-manifest> <final-evidence>}
FINAL=${2:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version> <temporary-manifest> <final-manifest> <final-evidence>}
EXPECTED=${3:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version> <temporary-manifest> <final-manifest> <final-evidence>}
TEMP_MANIFEST=${4:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version> <temporary-manifest> <final-manifest> <final-evidence>}
FINAL_MANIFEST=${5:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version> <temporary-manifest> <final-manifest> <final-evidence>}
FINAL_EVIDENCE=${6:?usage: finalize-artifact.sh <temporary.tgz> <final.tgz> <expected-version> <temporary-manifest> <final-manifest> <final-evidence>}
TEMP_EVIDENCE="$FINAL_EVIDENCE.tmp.$$"
trap 'rm -f "$TEMP_EVIDENCE"' EXIT HUP INT TERM

sh "$(dirname "$0")/version-smoke.sh" "$TEMP" "$EXPECTED"
python3 "$(dirname "$0")/../scripts/package_manifest.py" verify \
  --artifact "$TEMP" \
  --manifest "$TEMP_MANIFEST"
python3 "$(dirname "$0")/../scripts/package_manifest.py" evidence \
  --artifact "$TEMP" \
  --manifest "$TEMP_MANIFEST" \
  --version "$EXPECTED" \
  --output "$TEMP_EVIDENCE"
mv "$TEMP_MANIFEST" "$FINAL_MANIFEST"
mv "$TEMP_EVIDENCE" "$FINAL_EVIDENCE"
mv "$TEMP" "$FINAL"
