#!/usr/bin/env bash
set -euo pipefail
git config --global user.email setup-test@example.invalid
git config --global user.name "Setup test"
npm install --prefix "$RUNNER_TEMP/harness" @earendil-works/pi-coding-agent
export PATH="$RUNNER_TEMP/harness/node_modules/.bin:$PATH"
mix deps.get
sh packaging/assemble.sh
package=$(find _build/npm -maxdepth 1 -name '*.tgz')
build=$PWD/_build/npm/tightbeam
platform=$(node -p 'process.platform === "darwin" ? "darwin-aarch64" : "linux-x86_64"')
version=$("$build/bin/tightbeam" --version)
commit=$(git rev-parse HEAD)
tag=$(node -p "require('$build/setup-build.json').tag")
export TIGHTBEAM_SETUP_RELEASE_DIR="$RUNNER_TEMP/verified"
mkdir "$TIGHTBEAM_SETUP_RELEASE_DIR"
asset=tightbeam-$version-$platform-${commit:0:7}.tgz
cp "$package" "$TIGHTBEAM_SETUP_RELEASE_DIR/$asset"
(
  cd "$TIGHTBEAM_SETUP_RELEASE_DIR"
  shasum -a 256 "$asset" > SHA256SUMS
  printf '{"repository":"clickety-clacks/tightbeam","format":"tightbeam-release-provenance/v1","tag":"%s","commit":"%s"}\n' "$tag" "$commit" > release-provenance.json
)
if [ "$platform" = linux-x86_64 ]; then
  sudo loginctl enable-linger "$(id -un)"
  sudo systemctl start "user@$(id -u).service"
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi
export TIGHTBEAM_BASE_DIR="$RUNNER_TEMP/setup-org"
export TIGHTBEAM_LOCAL_OPENAI_ENDPOINT=http://127.0.0.1:25502/v1
export TIGHTBEAM_DEFAULT_HARNESS=pi
export TIGHTBEAM_DEFAULT_MODEL=local/compat-fixture
export TIGHTBEAM_DEFAULT_EFFORT=off
node "$RUNNER_TEMP/setup-model-evidence.mjs" &
trap 'kill "$!" 2>/dev/null || true' EXIT

snapshot() {
  for target in "$HOME/.local/bin/tightbeam" "$HOME/.local/share/tightbeam/current" "$TIGHTBEAM_BASE_DIR/setup.json" "$HOME/.local/share/tightbeam-chat/current" \
      "$HOME/.config/systemd/user/tightbeam.service" "$HOME/.config/systemd/user/tightbeam-chat.service" \
      "$HOME/Library/LaunchAgents/com.tightbeam.gateway.plist" "$HOME/Library/LaunchAgents/com.tightbeam.chat.plist" \
      /opt/tightbeam/current /etc/systemd/system/tightbeam.service /Library/LaunchDaemons/com.tightbeam.gateway.plist; do
    if [ -h "$target" ]; then
      printf '%s %s\n' "$target" "$(readlink "$target")"
    elif [ -f "$target" ]; then
      shasum -a 256 "$target"
    else
      printf '%s absent\n' "$target"
    fi
  done
  if [ "$platform" = linux-x86_64 ]; then
    systemctl show tightbeam --property=ActiveState,UnitFileState || true
    systemctl --user show tightbeam tightbeam-chat --property=ActiveState,UnitFileState || true
  else
    for endpoint in "gui/$(id -u)/com.tightbeam.gateway" "gui/$(id -u)/com.tightbeam.chat" system/com.tightbeam.gateway; do
      launchctl print "$endpoint" 2>/dev/null | awk '/state =|pid =/' || true
    done
  fi
}

setup() {
  "$build/bin/tightbeam" setup "$@"
}
snapshot > "$RUNNER_TEMP/before"
if [ "$SETUP_SCENARIO" = full ]; then
  initial=full
else
  initial=quick
fi
printf 'no\n' | setup --mode "$initial"
snapshot > "$RUNNER_TEMP/after"
diff -u "$RUNNER_TEMP/before" "$RUNNER_TEMP/after"
echo 'Decline filesystem and service diff: empty'
setup --mode "$initial" --yes | tee "$RUNNER_TEMP/first-turn.log"
grep -F "Main completed a turn" "$RUNNER_TEMP/first-turn.log"
"$HOME/.local/bin/tightbeam" --version
curl --fail --silent http://127.0.0.1:4178/chat-config.json
test -f "$TIGHTBEAM_BASE_DIR/state.db"
if [ "$initial" = quick ]; then
  if [ "$platform" = linux-x86_64 ]; then
    systemctl --user is-active tightbeam
    ss -ltn | grep '127.0.0.1:11373'
  else
    launchctl print "gui/$(id -u)/com.tightbeam.gateway" | grep 'state = running'
    lsof -nPiTCP:11373 -sTCP:LISTEN | grep '127.0.0.1:11373'
  fi
  printf 'retained\n' > "$TIGHTBEAM_BASE_DIR/upgrade-test"
  setup --mode full --yes
  test "$(cat "$TIGHTBEAM_BASE_DIR/upgrade-test")" = retained
fi
if [ "$platform" = linux-x86_64 ]; then
  systemctl is-enabled tightbeam
  systemctl is-active tightbeam
  ! systemctl --user is-active --quiet tightbeam
else
  sudo launchctl print system/com.tightbeam.gateway | grep 'state = running'
  ! launchctl print "gui/$(id -u)/com.tightbeam.gateway" 2>/dev/null
fi
snapshot > "$RUNNER_TEMP/before"
setup --mode full --yes
snapshot > "$RUNNER_TEMP/after"
diff -u "$RUNNER_TEMP/before" "$RUNNER_TEMP/after"
echo 'Idempotent re-run filesystem and service diff: empty'
