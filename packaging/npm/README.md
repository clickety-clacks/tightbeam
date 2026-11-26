# Tightbeam installer

Run `npx tightbeam --mode quick` to install and run setup on Apple Silicon
macOS or x86-64 Linux. The installer requires Node.js 20 or newer and tar.
Other arguments are passed through to `tightbeam setup`.

npm's `latest` tag selects the newest published installer. Each installer
downloads the exact GitHub release it was built for, verifies the archive
against that release's `SHA256SUMS`, and keeps the verified payload under
`~/.local/share/tightbeam-install`. The installer prints the executable's path.

GitHub release tags use the form `vX.Y.Z+BUILD`. To select an exact release, run
`npx tightbeam@X.Y.Z-build.BUILD`. In a project with a local Tightbeam dependency,
use `npx tightbeam@latest` to explicitly select npm's latest tag.

## Release publication

The stable GitHub release workflow publishes the matching npm tarball and
updates the tap from the published archives' verified checksums. Candidates
only render and dry-run the npm package.

Configure the source repository's Actions secret **HOMEBREW_TAP_TOKEN** with
Contents read/write access to the tap. For the first release, configure
**NPM_TOKEN** with an npm token that can create the public package and publish
with 2FA bypass. For subsequent releases, configure GitHub Actions Trusted
Publishing on the npm package for owner **clickety-clacks**, repository
**tightbeam**, workflow **publish-release.yml**, with direct publish enabled.
Trusted Publishing can replace the npm token after the bootstrap release.

If GitHub publication succeeds and distribution fails, correct the cause and
rerun the failed job in the same release workflow. The job verifies the exact
release is still GitHub's latest, accepts an existing npm version only if its
tarball integrity matches, and verifies npm latest and the remote tap after
updating them.
