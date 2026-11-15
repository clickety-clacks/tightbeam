# Release installation bundle

Every native Tightbeam package carries this directory. It is a template, not
permission to install a package. Render a fresh bundle for each tagged release
and its exact supported installed predecessor.

The release flow publishes a tagged candidate as a prerelease, kept out of the
latest-release position during its production soak. That candidate is built
and checked at its exact source commit by the normal release workflow. Its
package, `SHA256SUMS` and `release-provenance.json` are the inputs to this
renderer and to the existing selector. Candidate installation needs a separate
exact whole-action yes. After a healthy soak, promote the same release with
identical package bytes; do not rebuild it. A later install needs another exact
whole-action yes. The release metadata proves source and package identity;
approval, soak outcome and release-list status must be established separately.

1. Fill in `example-release.json` with the exact predecessor build ID, source
   prefix and schema stamp; the new tag, full source commit, package and asset
   digests; the required paths and service properties; and the expected new
   schema stamp and first-start effects. Record any base-directory files that
   this upgrade changes in `preflight_files` with their installed SHA-256.
2. Set `purpose` to `prerelease-soak` for the first install or
   `release-install` for a later install. Supply the tagged Linux package,
   `SHA256SUMS` and `release-provenance.json` together. The renderer checks
   their exact hashes, tag, source commit, workflow and package identity.
3. Rehearse the exact package, generated job and launcher on an isolated
   synthetic store at the supported database, WAL, archive, schema/index and
   writer scale. Measure the whole maintenance action and outage. Exercise
   the no-writer, post-boot and interrupted-terminal boundaries when job
   bytes change. Put measured times and limits in the manifest's `rehearsal`
   object; retain the nonsecret, hash-bound run record alongside the bundle.
   A missing or failed full-size run holds the installation request. Before
   the candidate install, also verify the prerelease is not latest; before a
   later install, verify the recorded healthy soak and unchanged package SHA.
4. Render into a new directory:

   ```sh
   python3 release-install/render_release.py exact-release.json release-assets exact-bundle
   ```

   The output has an exact manifest, launcher, maintenance job, plain-language
   install sheet and `SHA256SUMS`. Rehearse the final exact bundle if its bytes
   changed after the measured run. Review the bundle and its evidence before
   preparing the exact whole-action approval request.

The launcher verifies the package and installed predecessor before service
control. After a separate approval, its one command uses one sudo password;
there is no additional `RUN` prompt. The install sheet names the paths,
database effect, measured outage, backup and rollback limits. A mismatch or
uncertain terminal result is a stop, not a reason to retry the action.
