#!/bin/sh
# Write automatic-upgrade authority only after the tagged push release gate.
set -eu

destination=${1:?usage: write-release-provenance.sh <destination>}

# Candidate and manually dispatched workflows may build from a tag-shaped ref,
# but they are not publication. They must omit the authority entirely.
if [ "${TIGHTBEAM_RELEASE_TAG_VALIDATED:-}" != "1" ] ||
  [ "${GITHUB_EVENT_NAME:-}" != "push" ] ||
  [ "${GITHUB_REF_TYPE:-}" != "tag" ]; then
  exit 0
fi

tag=${GITHUB_REF_NAME:-}
commit=${CI_SOURCE_SHA:-}
github_sha=${GITHUB_SHA:-}
repository=${GITHUB_REPOSITORY:-}

if [ "${GITHUB_REF:-}" != "refs/tags/$tag" ] || [ -z "$tag" ]; then
  echo "packaging: validated release is missing its exact tag ref." >&2
  exit 1
fi

if [ "$commit" != "$github_sha" ] ||
  ! printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "packaging: validated release source SHA does not equal GITHUB_SHA." >&2
  exit 1
fi

if [ "$repository" != "clickety-clacks/tightbeam" ]; then
  echo "packaging: validated release provenance repository is not clickety-clacks/tightbeam." >&2
  exit 1
fi

printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$' || {
  echo "packaging: validated release tag has unsupported format." >&2
  exit 1
}

jq -n -S \
  --arg format "tightbeam-release-provenance/v1" \
  --arg repository "$repository" \
  --arg tag "$tag" \
  --arg commit "$commit" \
  '{commit: $commit, format: $format, repository: $repository, tag: $tag}' \
  > "$destination"
