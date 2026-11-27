# Optional Harklight people relay

Tightbeam setup, upgrades, and gateway startup leave this relay and any
existing relay installation alone. Run it only from a dedicated operator
account with Tightbeam relay permissions and an enrolled, supported
Harklight Agent. The relay uses Python 3 and its standard library. Keep both
the normal tightbeam and harklight-agent executables on the relay's PATH.

The upstream relay source, license, Git identity, and file checksums are
in source/. The examples and service definitions shipped there are inert.
Use the persistent Linux service described here in place of the upstream
finite-run timer. Run only one process or supervisor for each relay state
directory. Stop any previous foreground process and disable and stop any
previous timer before switching that directory to the persistent watcher.

## Install explicitly

In the unpacked Tightbeam archive, change directory to
optional/harklight-people-relay and copy the code into your account.

    runtime="$HOME/.local/share/tightbeam/people-relay"
    config="$HOME/.config/harklight-people-relay/config.json"
    install -d -m 0755 "$runtime"
    install -d -m 0700 "$(dirname "$config")"
    cp -R source/. "$runtime/"

If the config does not already exist, copy source/config.example.json to
the config path with mode 0600. Edit the config to point to the existing
Agent connection and authorized sender. Keep the config, the connection,
the state database and its Agent journal outside the copied code directory.

### Linux

The archive's systemd/ directory holds a user service template. It expects
the paths shown above and creates the private state directory under the
user service manager's state root (normally ~/.local/state). It looks
for Tightbeam and Harklight Agent in ~/.local/bin and standard system
locations. If it needs a different executable search path, set PATH in a
user-service override before starting it.

To install the template without starting the relay, run these commands
from optional/harklight-people-relay.

    unit=harklight-people-relay-watch.service
    install -d "$HOME/.config/systemd/user"
    install -m 0644 "systemd/$unit" "$HOME/.config/systemd/user/$unit"
    systemctl --user daemon-reload

To opt in to startup and run it now, run this separate command.

    systemctl --user enable --now harklight-people-relay-watch.service

To remove the service, disable and stop it first, remove the copied unit,
and reload the user manager. Remove the code directory only after stopping
any relay process that uses it.

    unit=harklight-people-relay-watch.service
    systemctl --user disable --now "$unit" &&
      rm -- "$HOME/.config/systemd/user/$unit" &&
      systemctl --user daemon-reload

### macOS

The archive provides no launchd service. To start the relay in the foreground:

    state="$HOME/.local/state/harklight-people-relay"
    install -d -m 0700 "$state"
    python3 "$runtime/relay.py" --config "$config" --state-dir "$state" --watch

Stop it with Ctrl-C before removing the code directory.

On either platform, leave the config, connection, database and journal in
place when removing the relay. Back up and restore the database and journal
together.
