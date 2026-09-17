# Agent instructions for propensive/.github

This repository holds the scripts and the reusable CI workflow that every Soundness-ecosystem
repository runs; `README.md` documents them and the dependency-pin scheme (`etc/refs`,
snapshots) they implement. Rules for changing them:

1. Consumers run the scripts at the commit pinned in their `etc/github-ref`, through their
   `etc/shared`. A merged change here reaches nobody until each repository bumps that pin, so
   a fix that consumers need must be followed by a one-line `etc/github-ref` bump in each.
   `scripts/shared` is the canonical copy of `etc/shared`; a change to it must be copied out.
2. The workflow `.github/workflows/scala-ci.yml` is referenced `@main` and takes effect on
   merge; keep it compatible with every consumer's current `etc/github-ref`.
3. Test a script change from a consumer checkout with
   `PROPENSIVE_GITHUB=/path/to/this/checkout make <target>` before opening the PR; every script
   is `bash -n`-clean and every Python file parses.
4. Never make a script silently overwrite something outside `~/.ivy2/local`, `out/`, or a
   temporary directory; and never publish (`gh release …`) from anything but a clean checkout
   of a commit that is already on GitHub.
