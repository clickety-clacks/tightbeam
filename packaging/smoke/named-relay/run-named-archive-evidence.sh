#!/usr/bin/env bash
set -euo pipefail
umask 077

archive=$(realpath "$1")
smoke=$(realpath "$2")
driver=$(dirname "$(realpath "$0")")
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox"

export RELAY_FAULT_SCRIPT="$driver/tightbeam-fault"
export RELAY_ARCHIVE="$archive" RELAY_GATEWAY_SMOKE="$smoke" RELAY_ARCHIVE_DRIVER="$driver/named-archive-runtime.py"

server=harklight-server-0.2.34-linux-x86_64.tar.gz
agent=harklight-agent-0.2.10-x86_64-unknown-linux-gnu.tar.gz
gh release download v0.2.34 --repo clickety-clacks/harklight-server --dir server \
  --pattern "$server" --pattern SHA256SUMS
gh release download v0.2.10 --repo clickety-clacks/harklight-agent --dir agent \
  --pattern "$agent" --pattern SHA256SUMS
printf '%s  %s\n' \
  72650db9ddebaeb9ee8410491d5c45840dcbe49f4acce9275c408a83bf5aad3 server/"$server" \
  9a7d9200e343265ed52205c89fd07d71a6d77c959d742dee18e30e89e6ba3f0 agent/"$agent" |
  sha256sum --check
bash "$driver/setup-release.sh" bash "$driver/enroll-and-test.sh"
echo "Disposable stock Server and archive acceptance completed."
