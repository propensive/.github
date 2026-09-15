# Shared repository infrastructure

Everything Propensive's repositories share: community files, reusable GitHub Actions
workflows, and the GitHub configuration they are all held to.

## Community files

`pull_request_template.md`, `contributing.md`, `code_of_conduct.md` and `security.md` are
GitHub's *default community health files*: every public repository under `propensive` that
does not carry its own copy uses these. Change them here, not in a repository. (A licence is
never inherited, so each repository keeps its own.)

## GitHub configuration

`bin/settings check` reports how each repository in `settings/repos.tsv` differs from the
settings, and `bin/settings apply` makes it match. The settings are:

 -  `settings/repository.json`: merge options and auto-merge, wiki/discussions/projects,
    secret scanning, the Actions token's default permissions, and which community files a
    repository must *not* override;
 -  `settings/ruleset.json`: the `rules` ruleset on `main`, which requires every change to
    arrive through a pull request with signed, linear history and passing checks;
 -  `settings/repos.tsv`: the repositories, and the status checks each one's ruleset
    requires. Check names depend on how a repository runs CI: a job `build` in a local
    workflow is `build`, while a job `build` calling one of the workflows below is
    `build / build`.

`propensive` is a personal account, so there are no account-level rulesets: `apply` copies
the ruleset into each repository. Add a repository by adding a line to `repos.tsv`, making
sure its checks already run on pull requests, and running `bin/settings apply <repo>`.

## `scala-ci.yml`

Builds a Mill-based Soundness application and runs its test suite. A consumer's workflow
reduces to naming its targets:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  build:
    uses: propensive/.github/.github/workflows/scala-ci.yml@main
    with:
      compile:       fume.client.compile
      publish_local: fume.client
      assembly:      fume.launcher.assembly
      test_assembly: fume.test.assembly
      test_main:     fume.Tests
```

Used by [pyrocosm](https://github.com/propensive/pyrocosm),
[fume](https://github.com/propensive/fume), [flame](https://github.com/propensive/flame) and
[xeq](https://github.com/propensive/xeq). The workflow expects of its caller:

 -  a checked-in `./mill` bootstrap wrapper;
 -  `val soundnessVersion = "X.Y.Z"` and `SOUNDNESS_SCALA_RELEASE", "…"` pins in `build.mill`,
    which it reads to key its caches and to sync the pinned Soundness release from GitHub
    Releases into `~/.ivy2/local` (using the release's own `sync_releases.py`, fetched from
    the same tag so script and release layout cannot drift apart).

`test_assembly` and `test_main` may be omitted for a repository whose suites cannot yet run
with plain `java`.

A `scala-release.yml` counterpart is deliberately deferred until Ziggurat owns the release
pipeline (soundness#1958); until then, releases run locally via each repository's
`make release`.

## `rust-ci.yml`

Runs `cargo test --workspace --locked` on a Cargo workspace, with the registry and target
directory cached. Used by [tel](https://github.com/propensive/tel) and
[xeq](https://github.com/propensive/xeq).

```yaml
jobs:
  build:
    uses: propensive/.github/.github/workflows/rust-ci.yml@main
```
