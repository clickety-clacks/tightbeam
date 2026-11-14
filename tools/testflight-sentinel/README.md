# TestFlight sentinel

The TestFlight sentinel is a manually run organization tool for delivering new
TestFlight crash submissions to the configured Tightbeam session recipients.
Run it on the organization host that has the existing App Store Connect helper
at `~/.appstoreconnect/asc-api.py`. From another host, invoke it through SSH as
one command:

```sh
ssh <operator>@<organization-host> '/absolute/path/to/testflight-sentinel register --app <numeric-app-id> --recipient <session-key>'
```

The executable in this directory can be called directly. If needed, invoke its
Python implementation directly:

```sh
python3 /absolute/path/to/sentinel.py register --app <numeric-app-id> --recipient '<session-key>'
python3 /absolute/path/to/sentinel.py register --app <numeric-app-id> --recipient '<another-session-key>'
python3 /absolute/path/to/sentinel.py list
python3 /absolute/path/to/sentinel.py unregister --app <numeric-app-id> --recipient '<session-key>'
python3 /absolute/path/to/sentinel.py unregister --app <numeric-app-id>
python3 /absolute/path/to/sentinel.py check
```

Registering the same app and recipient again is a no-op. Adding a recipient
keeps existing recipients. Unregistering an app or recipient preserves its
delivery history, so registering it again does not redeliver reports already
delivered to that recipient.

## Check behavior

Each check reads every registered app's crash submissions and follows Apple's
pagination links to the end. It uses only `GET` requests through the existing
helper's `api_get`; the helper loads the existing key in place. The sentinel
does not open key or settings files, mint tokens, or copy credentials. App
Store Connect failures are logged without changing that app's delivery
history; other registered apps continue.

New reports are batched into one `tightbeam wake` per recipient, submitted with
the process identity `testflight-sentinel`. A wake contains each report ID, app
name and ID, build number and available app version, device model, OS version,
submission time including its time zone, tester comment, and the crash-log
location or a reason it was not saved. Tester names and email addresses are
not included. A report is recorded as delivered only after Tightbeam accepts
the wake. A later check sends nothing for reports already delivered to that
recipient.

The saved crash-log root on the execution host is
`/mnt/shared-workspace/shared/testflight-sentinel/crash-logs/`; each report is
saved at `<app-id>/<report-id>.crash`. A wake includes both the execution-host
path and the path relative to the shared workspace. The shared workspace mount
root varies by host; common forms are `/mnt/shared-workspace`,
`~/shared-workspace`, and `/home/<local-user>/shared-workspace`. Use the mount
configured for the current host in the organization environment inventory.

Registration and delivery history are kept in
`~/.local/state/testflight-sentinel/state.json`; the log is
`~/.local/state/testflight-sentinel/testflight-sentinel.log`. The state and log
are owner-only. Acceptance checks and any future scheduled run use this same
state so reports accepted during manual checks are not sent again.

The intended standing schedule is a one-shot check every 30 minutes. This
change installs no timer or service. The sentinel runs only when an operator
invokes `check` until a separate exact approval authorizes a standing service.
