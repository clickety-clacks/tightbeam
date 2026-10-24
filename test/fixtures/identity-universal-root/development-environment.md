# Development and verification environment

Development and verification require the toolchains pinned by the repository,
including the BEAM toolchain and the release CLI compiler. When tools are not
on the default PATH, use the repository's documented environment setup.

Run verification against the exact revision being checked in an isolated
worktree. Record the baseline and resulting counts for the run.
