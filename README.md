# Shared repository infrastructure

Reusable GitHub Actions workflows for Propensive's Soundness-ecosystem applications
(currently [fume](https://github.com/propensive/fume) and
[flame](https://github.com/propensive/flame)).

## `scala-ci.yml`

Builds a Mill-based Soundness application and runs its test suite. A consumer's workflow
reduces to naming its targets:

```yaml
name: CI

on:
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

The workflow expects of its caller:

 -  a checked-in `./mill` bootstrap wrapper;
 -  `val soundnessVersion = "X.Y.Z"` and `SOUNDNESS_SCALA_RELEASE", "…"` pins in `build.mill`,
    which it reads to key its caches and to sync the pinned Soundness release from GitHub
    Releases into `~/.ivy2/local` (using the release's own `sync_releases.py`, fetched from
    the same tag so script and release layout cannot drift apart).

A `scala-release.yml` counterpart is deliberately deferred until Ziggurat owns the release
pipeline (soundness#1958); until then, releases run locally via each repository's
`make release`.
