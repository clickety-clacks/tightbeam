#!/usr/bin/env bash
set -euo pipefail

archive=$1
source_sha=$(git rev-parse HEAD)
platform=$(uname -s | tr 'A-Z' 'a-z')
root=$(mktemp -d "${RUNNER_TEMP:?This proof needs a disposable hosted runner}/relay-boundary.XXXXXXXX")
tar -xzf "$archive" -C "$root"
payload="$root/tightbeam"
relay="$payload/optional/harklight-people-relay"
runtime="$HOME/.local/share/tightbeam/people-relay"
config="$HOME/.config/harklight-people-relay/config.json"
state="$HOME/.local/state/harklight-people-relay"
unit=harklight-people-relay-watch.service
unit_file="$HOME/.config/systemd/user/$unit"

export TIGHTBEAM_BASE_DIR="$root/tightbeam-base"
export TIGHTBEAM_LOCAL_OPENAI_ENDPOINT=http://127.0.0.1:25502/v1
export TIGHTBEAM_DEFAULT_HARNESS=pi
export TIGHTBEAM_DEFAULT_MODEL=local/compat-fixture
export TIGHTBEAM_DEFAULT_EFFORT=off
export TIGHTBEAM_SETUP_RELEASE_DIR="$root/verified"
npm install --prefix "$root/harness" @earendil-works/pi-coding-agent
export PATH="$root/harness/node_modules/.bin:$PATH"

node "$(dirname "$0")/relay-setup-model.mjs" &
model=$!
relay_pid=
cleanup() {
  kill "$model" 2>/dev/null || true
  if [ -n "$relay_pid" ]; then kill "$relay_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

mkdir "$TIGHTBEAM_SETUP_RELEASE_DIR"
version=$("$payload/bin/tightbeam" --version)
tag=$(jq -er .tag "$payload/setup-build.json")
if [ "$platform" = linux ]; then
  arch=x86_64
  sudo loginctl enable-linger "$(id -un)"
  sudo systemctl start "user@$(id -u).service"
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
else
  arch=aarch64
fi
name="tightbeam-$version-$platform-$arch-${source_sha:0:7}.tgz"
cp "$archive" "$TIGHTBEAM_SETUP_RELEASE_DIR/$name"
(
  cd "$TIGHTBEAM_SETUP_RELEASE_DIR"
  shasum -a 256 "$name" > SHA256SUMS
  jq -n --arg tag "$tag" --arg commit "$source_sha" --arg asset "$name" '{
    repository:"clickety-clacks/tightbeam", format:"tightbeam-release-provenance/v1",
    tag:$tag, commit:$commit, checksums:"SHA256SUMS",
    assets:[$asset], workflow:"isolated relay packaging evidence"
  }' > release-provenance.json
)

assert_inactive() {
  if systemctl --user is-active --quiet "$unit" || systemctl --user is-enabled --quiet "$unit"; then
    echo "Relay service started or enabled outside the explicit activation step." >&2
    exit 1
  fi
}

assert_absent() {
  for path in "$runtime" "$config" "$state" "$unit_file" \
      "$HOME/Library/LaunchAgents/com.tightbeam.harklight-people-relay.plist"; do
    test ! -e "$path"
  done
  if [ "$platform" = linux ]; then
    assert_inactive
  fi
}

assert_absent
"$payload/bin/tightbeam" setup --mode quick --yes | tee "$root/quick.log"
grep -q '^READY:' "$root/quick.log"
assert_absent
echo "Fresh quick install and gateway startup left relay state, code and service absent."

# Install the optional files explicitly. Keep the process synthetic so this
# proof cannot contact a real Harklight connection.
install -d -m 0755 "$runtime"
install -d -m 0700 "$(dirname "$config")" "$state" "$root/agent"
cp -R "$relay/source/." "$runtime/"
install -m 0600 "$relay/source/config.example.json" "$config"
printf 'synthetic database\n' > "$state/relay.db"
printf 'synthetic journal\n' > "$state/journal"
printf 'synthetic connection\n' > "$root/agent/identity"
if [ "$platform" = linux ]; then
  install -d "$(dirname "$unit_file")" "$unit_file.d"
  install -m 0644 "$relay/systemd/$unit" "$unit_file"
  cat > "$unit_file.d/synthetic.conf" <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/sleep infinity
UNIT
  systemctl --user daemon-reload
  assert_inactive
  systemctl --user enable --now "$unit"
else
  test ! -e "$relay/systemd"
  sleep 1800 &
  relay_pid=$!
fi

snapshot() {
  shasum -a 256 "$config" "$state/relay.db" "$state/journal" \
    "$root/agent/identity" "$runtime/relay.py"
  if [ "$platform" = linux ]; then
    shasum -a 256 "$unit_file"
    systemctl --user show "$unit" -p ActiveState -p UnitFileState -p MainPID
  else
    kill -0 "$relay_pid"
  fi
}
snapshot > "$root/before"
"$payload/bin/tightbeam" setup --mode full --yes | tee "$root/full.log"
grep -q '^READY:' "$root/full.log"
snapshot > "$root/after"
cmp "$root/before" "$root/after"
echo "Full setup upgrade and gateway startup preserved opted-in relay state and supervisor."

shasum -a 256 "$config" "$state/relay.db" "$state/journal" "$root/agent/identity" > "$root/retained"
if [ "$platform" = linux ]; then
  systemctl --user disable --now "$unit"
  rm "$unit_file" "$unit_file.d/synthetic.conf"
  rmdir "$unit_file.d"
  systemctl --user daemon-reload
  assert_inactive
else
  kill "$relay_pid"
  wait "$relay_pid" || true
  relay_pid=
fi
rm -r "$runtime"
test ! -e "$runtime"
shasum -a 256 -c "$root/retained"
echo "Explicit relay removal preserved configuration, connection, database and journal."
