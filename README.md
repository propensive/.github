# Shared repository infrastructure

Reusable GitHub Actions workflows and scripts for Propensive's Soundness-ecosystem repositories
([soundness](https://github.com/propensive/soundness), [pyrocosm](https://github.com/propensive/pyrocosm),
[fume](https://github.com/propensive/fume), [flame](https://github.com/propensive/flame),
[flair](https://github.com/propensive/flair) and [xeq](https://github.com/propensive/xeq)).

## Scripts, through `etc/shared`

Each repository carries a copy of `scripts/shared` as `etc/shared`, and pins a commit of this
repository in `etc/github-ref`. `etc/shared <script> …` fetches that script at that commit
(cached under `~/.cache/propensive/github/<sha>/`) and runs it in the calling repository. Set
`PROPENSIVE_GITHUB=/path/to/this/checkout` to run a working copy instead.

| script | what it does |
|---|---|
| `sync-deps.sh` | installs every library pinned in `etc/refs`, transitively, and every tool's jars from `etc/tools`, into `~/.ivy2/local` |
| `tools.sh` | installs the commands pinned in `etc/tools` through their releases' installers |
| `snapshot.sh <name> <base>` | publishes an unreleased build as a `snapshot-<hex>` pre-release, for others to pin |
| `snapshot-prune.sh <name> [days]` | deletes old snapshot pre-releases |
| `deps.py walk\|check` | the pin file's transitive closure; `check` is the gate every release runs |
| `release-launcher.sh` | releases an application: its library jars, then its executables |
| `sync_releases.py`, `filtered_tree.py` | the helpers the above are built on |
| `xeq-fetch.sh`, `generate-install.sh` | the `xeq` builder pin, and the installer script |

## Dependency pins: `etc/refs`

Every propensive library a repository builds against is pinned in `etc/refs`, one per line,
tab-separated:

```
# repository            version               commit (snapshots only)
propensive/soundness    0.66.0
propensive/pyrocosm     0.2.0-3f9a1c2b7d4e    8c1e0d5a9b2f…(40 hex)
```

A version `X.Y.Z` is a **release**, the jars under the GitHub Release of that tag. A version
`X.Y.Z-<12 hex>` is a **snapshot**: an unreleased build, published by `make snapshot` in the
upstream repository as the pre-release tagged `snapshot-<12 hex>`, where the hex is the start
of the *filtered tree hash* of the commit it was built from (its tree minus everything
`.dockerignore` excludes, so a rebase or a documentation change does not make a new snapshot)
and `X.Y.Z` is the version that repository declares for its next release. A snapshot sorts
below the release it precedes, so once `X.Y.Z` is released, bumping the pin is enough.

Pins are transitive: a snapshot's own `etc/refs` (at the pinned tag) names what it was
built against, and `sync-deps.sh` installs that too. A snapshot must be pinned identically
wherever it is reached; two releases of one library merely evict as usual.

The build reads the file through a `deps` object in `build.mill`, so the pin lives in one
place; the CI cache is keyed on the file's hash. `Task.Source`, not a `val`: the Mill daemon
only re-evaluates the build script when `build.mill` changes.

```scala
object deps extends Module:
  def file = Task.Source(mill.api.BuildCtx.workspaceRoot / "etc" / "refs")
  def pins: T[Map[String, String]] = Task:
    os.read.lines(file().path).map(_.trim).filter(l => l.nonEmpty && !l.startsWith("#"))
      .map(_.split("\t").map(_.trim).filter(_.nonEmpty))
      .map(cols => cols(0).stripPrefix("propensive/") -> cols(1)).toMap
  def version(name: String): Task[String] = Task.Anon:
    pins().getOrElse(name, sys.error(s"etc/refs has no pin for $name"))

// then, in a module:
def mvnDeps = Task(Seq(mvn"dev.propensive:pyrocosm-model:${deps.version("pyrocosm")()}"))
```

## Tools are pinned in `etc/tools`, and are always releases

A **dependency** is what a repository's jars are compiled against, and what their POMs will
name: Soundness for Pyrocosm, Pyrocosm for fume. A **tool** is what a repository *runs*: fume
to run its tests, flair to check its sources, the flair compiler plugin Soundness loads with
`-Xplugin`. A tool never appears in a POM, so it is pinned separately, in `etc/tools`, in the
same shape as `etc/refs` but with two rules: a tool is always a release (`deps.py` rejects a
snapshot there), and a tool is not part of the transitive closure and does not gate a release,
because a release of it exists by definition.

```
# repository          version
propensive/fume       0.3.0
propensive/flair      0.2.0
```

This is what keeps the release graph acyclic. Soundness runs flair, flair depends on Pyrocosm,
Pyrocosm depends on Soundness; were the first of those a dependency, no one of the three could
be released before the other two. `sync-deps.sh` installs a tool's jars (for a plugin), and
`make tools` runs `tools.sh`, which installs a tool's command through its release's
`install.sh`. A repository that is both a tool to one consumer and a dependency to another is
simply named in both files, by their respective consumers.

### The flow

1. In the upstream (Soundness, say), commit the change a downstream needs, and run
   `make snapshot`. It stages the jars at `<next>-<hex>`, installs them locally, uploads them
   as `snapshot-<hex>` (skipped if that snapshot already exists), and prints the pin line.
2. In the downstream, paste the line into `etc/refs`. `make sync-deps` installs it (or,
   for a snapshot not yet on GitHub, builds it from the sibling checkout named by the commit);
   CI does the same on the PR, which can now merge.
3. When the upstream is released, replace the pin with the release. `make release` refuses to
   run while any pin, transitively, is a snapshot (`deps.py check`).
4. `make snapshot-prune` in the upstream, occasionally.

The repository's own version stays a plain `val <name>Version = "X.Y.Z"` in `build.mill`;
`publishVersion` is a `Task.Input` that `<NAME>_RELEASE_VERSION` overrides through `Task.env`,
which is how `snapshot.sh` drives the snapshot version through a running Mill daemon.

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
```

The workflow expects of its caller: a checked-in `./mill` bootstrap wrapper; `etc/shared` and
`etc/github-ref`; `etc/refs`, which it syncs with `sync-deps.sh` before building; `etc/tools`
naming the fume release that runs the suites in `test_assembly` (installed with `tools.sh`);
and the `SOUNDNESS_SCALA_RELEASE", "…"` toolchain pin in `build.mill`, which keys the
toolchain cache. `test_main` is ignored: fume discovers the suites from the assembly.

Releases run locally via each repository's `make release`; a `scala-release.yml` counterpart is
deferred until Ziggurat owns the release pipeline (soundness#1958).
