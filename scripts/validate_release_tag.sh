#!/bin/sh
set -eu

tag=${1:-}
tagged_sha=${2:-}
mode=${3:-}

[ -n "$tag" ] && [ -n "$tagged_sha" ] && [ "$#" -le 3 ] || {
  echo "usage: scripts/validate_release_tag.sh v<major>.<minor>.<patch>+<build> <commit> [--selected-candidate]" >&2
  exit 2
}

case "$mode" in
  "") ;;
  --selected-candidate)
    printf '%s\n' "$tagged_sha" | grep -Eq '^[0-9a-f]{40}$' || {
      echo "release: selected candidate must be an exact lower-case 40-hex SHA" >&2
      exit 1
    }
    ;;
  *)
    echo "release: unknown validation mode $mode" >&2
    exit 2
    ;;
esac

printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$' || {
  echo "release: tag must be exactly v<major>.<minor>.<patch>+<build>" >&2
  exit 1
}

identity=${tag#v}
version=${identity%%+*}
build=${identity##*+}
declared_version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' cli/Cargo.toml)

[ "$version" = "$declared_version" ] || {
  echo "release: tag version $version does not match cli/Cargo.toml version $declared_version" >&2
  exit 1
}

actual_build=$(git rev-list --count "$tagged_sha")
[ "$build" = "$actual_build" ] || {
  echo "release: tag build $build does not match commit build $actual_build" >&2
  exit 1
}

canonical_ref="refs/heads/main"

if [ "$mode" = --selected-candidate ]; then
  tracking_ref="refs/remotes/origin/main"
  git fetch --no-tags origin "+$canonical_ref:$tracking_ref"
  canonical_sha=$(git rev-parse --verify "$tracking_ref")
  git merge-base --is-ancestor "$tagged_sha" "$canonical_sha" || {
    echo "release: selected candidate $tagged_sha is not in canonical $canonical_ref history at $canonical_sha" >&2
    exit 1
  }
  exit 0
fi

canonical_sha=$(git ls-remote --heads origin "$canonical_ref" | awk 'NR == 1 {print $1}')
[ -n "$canonical_sha" ] || {
  echo "release: canonical branch $canonical_ref does not exist on origin" >&2
  exit 1
}

[ "$tagged_sha" = "$canonical_sha" ] || {
  echo "release: tagged commit $tagged_sha is not the canonical $canonical_ref tip $canonical_sha" >&2
  exit 1
}
