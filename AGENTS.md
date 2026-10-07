# Agent instructions for propensive/.github

This repository holds the scripts and the reusable CI workflow that every Soundness-ecosystem
repository runs; `README.md` documents them and the pin scheme they implement: dependencies in
`etc/refs` (releases or snapshots, walked transitively, gated at release) and tools in
`etc/tools` (releases only, never walked, never gating — which is what keeps the release graph
free of cycles). Rules for changing them:

1. Consumers run the scripts at the commit pinned in their `etc/github-ref`, through their
   `etc/shared`. A merged change here reaches nobody until each repository bumps that pin, so
   a fix that consumers need must be followed by a one-line `etc/github-ref` bump in each.
   `scripts/shared` is the canonical copy of `etc/shared`; a change to it must be copied out.
2. The workflows `.github/workflows/scala-ci.yml` and `.github/workflows/scala-release.yml` are
   referenced `@main` and take effect on merge; keep them compatible with every consumer's
   current `etc/github-ref`.
3. Test a script change from a consumer checkout with
   `PROPENSIVE_GITHUB=/path/to/this/checkout make <target>` before opening the PR; every script
   is `bash -n`-clean and every Python file parses.
4. Never make a script silently overwrite something outside `~/.ivy2/local`, `out/`, or a
   temporary directory; and never publish (`gh release …`) from anything but a clean checkout
   of a commit that is already on GitHub.
5. `scripts/release.sh` publishes, and on failure deletes the tag it was triggered by, so a
   change to it is tested with `RELEASE_DRY_RUN=1` from a consumer checkout before the PR:
   `PROPENSIVE_GITHUB=/path/to/this/checkout RELEASE_DRY_RUN=1 ./etc/shared release.sh X.Y.Z`
   runs every gate, builds, stages and prints the notes without publishing anything. Keep the
   gates in the phase that runs *before* the rollback trap is armed: a gate that fails after it
   deletes a tag that was never the problem. `scripts/release_notes.py` can be run by hand
   against an already-published version.
6. The release key's seed, `UPGRADE_SIGNING_SEED`, is read once at the top of `release.sh`,
   unset, and handed only to `xek` through the environment of that one command. Never echo it,
   write it to a file, pass it as an argument, or let a command the script `eval`s see it; and
   never handle a recovery seed at all, which lives offline. Rehearse signing with throwaway
   keys from `xek keygen`.
