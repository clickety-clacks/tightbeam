# Tightbeam

Tightbeam is like a machined part for running models in their own harness and taking care of everything else they need to function as an organization. The native harnesses are already great at orchestrating subagents, so Tightbeam leaves that to them. You can install Tightbeam by pointing your coding agent at this README.

Just want to try it? [Use the quick install](#quick-install).

Both install paths support macOS on Apple silicon and Linux on x86-64. Have a supported harness CLI on your PATH. Use one install method. The npx command requires Node.js 24 or newer and `tar`, and runs setup for you. With Homebrew, run setup after installing the package.

## Quick install

Quick mode needs no root access. It runs locally for a single user and uses lighter isolation than full mode.

With npx:

```sh
npx tightbeam --mode quick
```

With Homebrew:

```sh
brew install clickety-clacks/tap/tightbeam
tightbeam setup --mode quick
```

## Full install

Use full mode for a permanent installation. Switching from quick to full mode on the same release keeps your data. If you’re also updating to a newer release, run quick setup on that release before switching to full mode.

With npx:

```sh
npx tightbeam --mode full
```

With Homebrew:

```sh
brew install clickety-clacks/tap/tightbeam
tightbeam setup --mode full
```

Setup shows its plan and asks for confirmation before proceeding. If your coding agent is installing for you, stay available to confirm the plan and authorize administrator access when prompted.

For releases without `tightbeam setup`, follow the [install instructions for your release](https://github.com/clickety-clacks/tightbeam/blob/v0.1.16%2B4304/README.md#from-a-release-package).

After either install, we recommend learning [Uncle Enzo](docs/AGENTS-AND-SETTINGS.md#archetypes-and-kungfu), Tightbeam’s primary kungfu bundle.

## Documentation

- [Agents, archetypes, and settings](docs/AGENTS-AND-SETTINGS.md)
- [Checking and removing an installation](docs/OPERATING.md)
- [Existing installations and upgrades](docs/UPGRADE.md)
- [Architecture](docs/ARCHITECTURE.md) and [adding a machine](docs/SATELLITE.md)
- [Developing Tightbeam](docs/DEVELOPMENT.md)
