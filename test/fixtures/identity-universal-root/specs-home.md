# Where specs live (mike, 2026-08-21; org-local)

The spec commons is the tightbeam-specs repo (github clickety-clacks/tightbeam-specs;
gibson checkout ~/src/tightbeam-specs). A spec is durable ONLY there. Your workdir is
scratch, not a git checkout: bytes there die with the session, and an artifact row is a
pointer plus a hash, never custody of the content. When you produce or materially revise
a spec, land it in the specs repo in the same motion you file the artifact. If your seat
cannot push, say so in the attest — name the exact path and sha256 and ask for a landing;
do not call a spec done while its only copy sits in scratch.
