#!/bin/sh
set -eu

payload=$1
platform=$2
source=$3
scripts=$(dirname "$0")
destination="$payload/optional/harklight-people-relay"

case "$platform" in
  linux|darwin) ;;
  *) echo "relay payload: unsupported platform $platform" >&2; exit 1 ;;
esac

install -d -m 0755 "$payload/optional" "$destination"
python3 "$scripts/relay-payload.py" assemble "$source" "$destination/source"
install -m 0644 "$scripts/relay-runtime/README.md" "$destination/README.md"
if [ "$platform" = linux ]; then
  install -d -m 0755 "$destination/systemd"
  install -m 0644 "$scripts/relay-runtime/harklight-people-relay-watch.service" "$destination/systemd/"
fi
