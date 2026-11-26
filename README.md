# Tightbeam

Tightbeam is like a machined part for running models in their own harness and taking care of everything else they need to function as an organization. The native harnesses are already great at orchestrating subagents, so Tightbeam leaves that to them. You can install Tightbeam by pointing your coding agent at this README.

Just want to try it? [Use the quick install](#quick-install).

Both install paths support macOS on Apple silicon and Linux on x86-64. Use one package manager. The npx command runs setup for you. With Homebrew, run setup after installing the package.

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

Use full mode for a permanent installation. You can run it over a quick installation to upgrade in place and keep your data.

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

For releases without `tightbeam setup`, follow the [install instructions for your release](https://github.com/clickety-clacks/tightbeam/releases).

## Documentation

- [Agents, archetypes, and settings](docs/AGENTS-AND-SETTINGS.md)
- [Existing installations and upgrades](docs/UPGRADE.md)
- [Architecture](docs/ARCHITECTURE.md) and [adding a machine](docs/SATELLITE.md)
- [Developing Tightbeam](docs/DEVELOPMENT.md)
