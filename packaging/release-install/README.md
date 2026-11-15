# Release installation bundle

Every native Tightbeam package carries this directory. It is a template, not
permission to install a package. Render a fresh bundle for each published
release and its exact supported installed predecessor.

The release flow first builds an unpublished candidate from one source commit.
An installation of that candidate needs its own exact approval and a reviewed
candidate packet. After a healthy production soak, publication reuses the
candidate package bytes. The published release carries the candidate proof,
`SHA256SUMS`, and release provenance. A later installation of that published
release needs a separate exact approval. This renderer consumes the published
assets; it does not turn an unpublished candidate into a published release.

1. Fill in `example-release.json` with the exact predecessor build ID, source
   prefix and schema stamp; the new tag, full source commit, package and asset
   digests; the required paths and service properties; and the expected new
   schema stamp and first-start effects. Record any base-directory files that
   this upgrade changes in `preflight_files` with their installed SHA-256.
2. Verify that the published package bytes equal the approved, healthy
   candidate's package digest. Supply the four published assets together:
   the Linux package, `SHA256SUMS`, `release-candidate-manifest.json`, and
   `release-provenance.json`. The renderer checks the hashes and the proof,
   approval, soak, source and tag links before producing a bundle.
3. Rehearse the exact package, generated job and launcher on an isolated
   synthetic store at the supported database, WAL, archive, schema/index and
   writer scale. Measure the whole maintenance action and outage. Exercise
   the no-writer, post-boot and interrupted-terminal boundaries when job
   bytes change. Put measured times and limits in the manifest's `rehearsal`
   object; retain the nonsecret, hash-bound run record alongside the bundle.
   A missing or failed full-size run holds the installation request.
4. Render into a new directory:

   ```sh
   python3 release-install/render_release.py exact-release.json published-assets exact-bundle
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
