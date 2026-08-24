#!/bin/sh
set -eu

tag=${1:-}
tagged_sha=${2:-}

[ -n "$tag" ] && [ -n "$tagged_sha" ] || {
  echo "usage: scripts/validate_release_tag.sh v<major>.<minor>.<patch>+<build> <commit>" >&2
  exit 2
}

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

case "$version" in
  0.1.*) canonical_ref="refs/heads/$version" ;;
  *) canonical_ref="refs/heads/main" ;;
esac

canonical_sha=$(git ls-remote --heads origin "$canonical_ref" | awk 'NR == 1 {print $1}')
[ -n "$canonical_sha" ] || {
  echo "release: canonical branch $canonical_ref does not exist on origin" >&2
  exit 1
}

[ "$tagged_sha" = "$canonical_sha" ] || {
  echo "release: tagged commit $tagged_sha is not the canonical $canonical_ref tip $canonical_sha" >&2
  exit 1
}
