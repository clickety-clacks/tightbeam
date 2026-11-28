#!/bin/sh
# Write automatic-upgrade authority for validated tags and canonical main candidates.
set -eu

destination=${1:?usage: write-release-provenance.sh <destination>}

github_sha=${GITHUB_SHA:-}
repository=${GITHUB_REPOSITORY:-}

if [ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ] &&
   [ "${GITHUB_REF_TYPE:-}" = "branch" ] &&
   [ "${GITHUB_REF:-}" = "refs/heads/main" ] &&
   [ "$repository" = "clickety-clacks/tightbeam" ] &&
   [ "${CANDIDATE_BRANCH:-}" = "main" ] &&
   [ "${GITHUB_WORKFLOW_REF:-}" = "$repository/.github/workflows/release-candidate.yml@refs/heads/main" ]; then
  commit=${CANDIDATE_SHA:-}
  if [ "${GITHUB_REF_NAME:-}" != "main" ] ||
     [ "${CANDIDATE_REF:-}" != "refs/heads/main" ] ||
     [ "$commit" != "$github_sha" ] ||
     [ "$commit" != "${GITHUB_WORKFLOW_SHA:-}" ] ||
     ! printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' ||
     [ "$(git rev-parse HEAD)" != "$commit" ]; then
    echo "packaging: canonical candidate ref, source, workflow and checkout must agree." >&2
    exit 1
  fi

  if ! git diff --quiet "$commit" -- cli/Cargo.toml; then
    echo "packaging: candidate version declaration differs from its exact source." >&2
    exit 1
  fi

  version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' cli/Cargo.toml)
  build=$(git rev-list --count "$commit")
  tag="v$version+$build"
  sh scripts/validate_release_tag.sh "$tag" "$commit" --selected-candidate
elif [ "${TIGHTBEAM_RELEASE_TAG_VALIDATED:-}" = "1" ] &&
     [ "${GITHUB_EVENT_NAME:-}" = "push" ] &&
     [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  tag=${GITHUB_REF_NAME:-}
  commit=${CI_SOURCE_SHA:-}
  if [ "${GITHUB_REF:-}" != "refs/tags/$tag" ] || [ -z "$tag" ]; then
    echo "packaging: validated release is missing its exact tag ref." >&2
    exit 1
  fi
else
  exit 0
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
