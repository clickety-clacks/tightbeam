#!/bin/sh
set -eu

usage() {
  echo "usage: scripts/release_candidate.sh [--check] release-candidate/<name> <protected-base-sha> <reviewed-feature-sha>..." >&2
  exit 2
}

check_only=0
if [ "${1:-}" = "--check" ]; then
  check_only=1
  shift
fi

[ "$#" -ge 3 ] || usage

branch=$1
base=$2
shift 2

case "$branch" in
  release-candidate/*) ;;
  *)
    echo "release candidate: branch must start with release-candidate/." >&2
    exit 1
    ;;
esac

git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || {
  echo "release candidate: invalid branch name $branch." >&2
  exit 1
}

git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "release candidate: run this command in a Git worktree." >&2
  exit 1
}

[ -z "$(git status --porcelain=v1)" ] || {
  echo "release candidate: the worktree is dirty." >&2
  exit 1
}

is_sha() {
  value=$1
  [ "${#value}" -eq 40 ] &&
    [ "$value" = "$(printf '%s' "$value" | tr 'A-F' 'a-f')" ] &&
    ! printf '%s' "$value" | grep -q '[^0-9a-f]'
}

is_sha "$base" || {
  echo "release candidate: protected base must be an exact lower-case 40-hex SHA." >&2
  exit 1
}

git cat-file -e "$base^{commit}" 2>/dev/null || {
  echo "release candidate: protected base $base is not a commit." >&2
  exit 1
}

remote_maintenance=$(git rev-parse --verify refs/remotes/origin/0.1.x 2>/dev/null) || {
  echo "release candidate: refs/remotes/origin/0.1.x is missing; fetch origin/0.1.x first." >&2
  exit 1
}

if [ "$check_only" -eq 0 ]; then
  [ "$remote_maintenance" = "$base" ] || {
    echo "release candidate: protected base $base is not the fetched origin/0.1.x $remote_maintenance." >&2
    exit 1
  }
else
  git merge-base --is-ancestor "$base" "$remote_maintenance" || {
    echo "release candidate: protected base $base is not an ancestor of origin/0.1.x $remote_maintenance." >&2
    exit 1
  }
fi

features=
for feature in "$@"; do
  is_sha "$feature" || {
    echo "release candidate: reviewed feature must be an exact lower-case 40-hex SHA: $feature." >&2
    exit 1
  }
  git cat-file -e "$feature^{commit}" 2>/dev/null || {
    echo "release candidate: reviewed feature $feature is not a commit." >&2
    exit 1
  }
  case "
$features
" in
    *"
$feature
"*)
      echo "release candidate: duplicate reviewed feature $feature." >&2
      exit 1
      ;;
  esac
  features="${features}${features:+
}$feature"
done

candidate=$1
for feature in "$@"; do candidate=$feature; done

git merge-base --is-ancestor "$base" "$candidate" || {
  echo "release candidate: candidate $candidate is not descended from protected base $base." >&2
  exit 1
}
[ "$base" != "$candidate" ] || {
  echo "release candidate: candidate must contain at least one reviewed feature." >&2
  exit 1
}

expected=$(git rev-list --reverse --topo-order "$base..$candidate")
[ -n "$expected" ] || {
  echo "release candidate: protected base and candidate have an empty range." >&2
  exit 1
}
[ "$features" = "$expected" ] || {
  echo "release candidate: reviewed feature SHAs are missing, reordered, extra, or non-ancestral." >&2
  echo "release candidate: expected the exact ordered range:" >&2
  printf '%s\n' "$expected" >&2
  exit 1
}

if [ "$check_only" -eq 0 ]; then
  ! git show-ref --verify --quiet "refs/heads/$branch" || {
    echo "release candidate: local branch $branch already exists." >&2
    exit 1
  }
  if git ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
    echo "release candidate: remote branch $branch already exists." >&2
    exit 1
  else
    remote_status=$?
    [ "$remote_status" -eq 2 ] || {
      echo "release candidate: could not read branch $branch from origin." >&2
      exit 1
    }
  fi
  git switch --create "$branch" "$candidate" >&2
fi

origin=$(git config --get remote.origin.url)
repository=$(printf '%s' "$origin" | sed -E \
  -e 's#^git@github\.com:##' \
  -e 's#^https://github\.com/##' \
  -e 's#\.git$##')

python3 - "$repository" "refs/heads/$branch" "$base" "$@" <<'PY'
import json
import sys

repository, candidate_ref, protected_base_sha, *features = sys.argv[1:]
manifest = {
    "candidate_ref": candidate_ref,
    "protected_base_sha": protected_base_sha,
    "repository": repository,
    "reviewed_feature_shas": features,
    "schema": "tightbeam-release-candidate-input/v1",
    "source_sha": features[-1],
}
print(json.dumps(manifest, sort_keys=True, separators=(",", ":")))
PY
