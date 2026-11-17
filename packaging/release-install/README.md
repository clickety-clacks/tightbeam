# Release installation bundle

Every native Tightbeam package carries this directory. It is a template, not
permission to install a package. Render a fresh bundle for each candidate or
published release and its exact supported installed predecessor.

For the first install, use the successful main candidate run's
`release-candidate-stage-<sha>` artifact. It contains selector-ready package
files, the canonical `release-candidate-manifest.json`, unpublished candidate
`release-provenance.json`, and `SHA256SUMS`. The candidate provenance names the
workflow at top level and records the candidate run, workflow SHA and proof
manifest hash. Its tag is planned metadata only: no Git tag or GitHub Release
exists before the soak. The renderer verifies the package against the proof
manifest and the selector's package checksum before producing an install
bundle. A candidate install requires separate exact whole-action approval. Publish those
identical package bytes only after a healthy soak; do not rebuild them. A later
install requires another exact approval. The release metadata proves source
and package identity; approval and soak outcome must be established separately.

1. Fill in `example-release.json` with the exact predecessor build ID, source
   prefix and schema stamp; the new tag, full source commit, package and asset
   digests; the required paths and service properties; and the expected new
   schema stamp and first-start effects. Record any base-directory files that
   this upgrade changes in `preflight_files` with their installed SHA-256.
2. Set `purpose` to `candidate-soak` for the first install or
   `release-install` for a later install. For a candidate, supply the Linux
   package, `SHA256SUMS`, `release-provenance.json` and
   `release-candidate-manifest.json` from the same candidate-stage artifact.
   The renderer checks their exact hashes, planned tag, source commit, workflow
   run, proof manifest and package identity. For a later install, supply the
   published package, checksums, provenance and candidate manifest together.
3. Rehearse the exact package, generated job and launcher on an isolated
   synthetic store at the supported database, WAL, archive, schema/index and
   writer scale. Measure the whole maintenance action and outage. Exercise
   the no-writer, post-boot and interrupted-terminal boundaries when job
   bytes change. Put measured times and limits in the manifest's `rehearsal`
   object; retain the nonsecret, hash-bound run record alongside the bundle.
   A missing or failed full-size run holds the installation request. Before
   candidate installation, verify the approval names the exact candidate SHA
   and package; before a later install, verify the recorded healthy soak and
   unchanged package SHA.
4. Render into a new directory:

   ```sh
   python3 release-install/render_release.py exact-release.json release-assets exact-bundle
   ```

   The output has an exact manifest, launcher, maintenance job, plain-language
   install sheet and `SHA256SUMS`. Rehearse the final exact bundle if its bytes
   changed after the measured run. Review the bundle and its evidence before
   preparing the exact whole-action approval request.

The launcher verifies the package, candidate proof when present, and installed
predecessor before service control. After a separate approval, its one command uses one sudo password;
there is no additional `RUN` prompt. The install sheet names the paths,
database effect, measured outage, backup and rollback limits. A mismatch or
uncertain terminal result is a stop, not a reason to retry the action.

A failed candidate or unhealthy soak remains unpublished. Fix the source in a
reviewed change to `main` and build a fresh candidate. If a release is already
published and later proves defective, keep it available with a do-not-install
warning naming the failure and safe replacement, and mark it prerelease so it
cannot be latest.
