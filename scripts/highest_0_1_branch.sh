#!/bin/sh
set -eu

highest=$(
  git for-each-ref --format='%(refname)' 'refs/remotes/origin/0.1.*' |
    sed -n '/^refs\/remotes\/origin\/0\.1\.[0-9][0-9]*$/p' |
    LC_ALL=C sort -t. -k3,3n |
    tail -n 1
)

[ -n "$highest" ] || {
  echo "maintenance branch: no remote-tracking branch matches origin/0.1.<number>." >&2
  exit 1
}

printf '%s\n' "$highest"
