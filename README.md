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
| `release.sh` | publishes the tagged version: the gates, the jars, and (for an application) its executables |
| `release_notes.py` | the release notes, assembled the same way for every repository |
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
3. When the upstream is released, replace the pin with the release. A release refuses to run
   while any pin, transitively, is a snapshot (`deps.py check`).
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

## `scala-release.yml`, and releasing by tagging

A release is cut by tagging, and nothing else:

```sh
git tag -s 1.2.3 && git push --tags
```

The tag fires the repository's `.github/workflows/release.yml`, fourteen lines which call
`scala-release.yml` here; that checks out the tag, restores the same caches as `scala-ci.yml`
(but never `out/` — a release builds from a cold tree) and runs `etc/shared release.sh`. The tag
therefore exists *before* anything is built: it is the trigger, not the last step, which is the
one substantive difference from the three scripts this replaced. The calling job must grant
`permissions: contents: write`; the organisation default is read-only.

`release.sh` gates first, and publishes nothing until every gate has passed:

- the tag is **signed and verified** by GitHub, and names `HEAD`;
- **CI is already green** on that commit — the release does not re-run the suite. Runs of the
  release workflow itself are ignored, so a rolled-back attempt does not block the retry;
- `val <name>Version` in `build.mill`, where the repository has one, equals the tag;
- the migration notes, where the repository keeps them, are finalised for this version;
- every `verify` command in `etc/release` passes;
- `deps.py check`: every pin, transitively, is a published release.

If anything fails after that, the release **and the tag** are deleted from origin, so the retry
is `git tag -d 1.2.3 && git tag -s 1.2.3 && git push --tags` once the cause is fixed.
`RELEASE_DRY_RUN=1` runs every gate, builds, stages and prints the notes without publishing,
and previews the pull requests the release would open in its consumers.

### What varies: `etc/release`

One `key<TAB>value` line each (a run of spaces separates them just as well, so the file can be
aligned), `#` for comments. An unknown key is an error — a mistyped `migration` would otherwise
silently drop a gate.

| key | what it says |
|---|---|
| `name` | the repository and application name; gives `propensive/<name>` and `<NAME>_RELEASE_VERSION` |
| `title` | the release title prefix — `flair`, but `Soundness` |
| `build` | mill targets run, in order, before `release.stage` |
| `launcher` | the launcher module, when executables are published; absent for a library |
| `hints` | the `--github` publication homes Burdock matches the classpath against |
| `probes` | modules whose `publishVersion` must equal the tag before anything is published |
| `migration` | the migration-notes directory, when the repository keeps them |
| `verify` | an extra gate command; may be repeated, and each is run in order |

The library list is *not* declared: it is read from the filenames `release.stage` produces. Nor
is the version pin: `release.sh` looks for `val <name>Version` in `build.mill` itself.

### Two publication orders, and why

A **library** repository (Soundness, Pyrocosm) publishes a draft, uploads in batches of fifty,
checks every asset's digest against the local file, and only then makes the release visible, so
nothing partial is ever seen.

An **application** repository (fume, flame, flair) cannot use a draft: its executables
externalize each library by matching a SHA-256 against the release's *published* assets, and a
draft's asset URLs live under an `untagged-…` path that changes on publication, which would bake
dead URLs into them. So the release is made in two steps, exactly as it must be consumed — the
library jars first, then, once GitHub has indexed their digests, the repackaged executables, the
polyglot bootstrap and the installer. The script refuses to upload an executable that inlined a
library instead of referring to the release.

### Proposing a release to its consumers: `etc/downstream`

A repository that names its consumers in `etc/downstream` — one repository per line, `#` for
comments — has each release proposed to them as a draft pull request, once it is published. The
chain is declared where it starts, and only as far as the next link: xek names Soundness,
Soundness names Pyrocosm, and Pyrocosm names fume, flame and flair.

```
# etc/downstream in Pyrocosm
propensive/fume
propensive/flame
propensive/flair
```

`propagate.py` makes each pull request, on a branch `pins/<name>-<version>` of the consumer. It
moves the released repository's pin in the consumer's `etc/refs` to the release, and every other
pin the consumer shares with the release's own `etc/refs` to the version the release was built
against; and it moves the consumer's `etc/xeq.tsv` to the release's. So a Pyrocosm release
carries the Soundness and the xek it was built against to fume, flame and flair in one pull
request each. A pin only moves forwards — a consumer already on something newer keeps it — and a
consumer with nothing to change, or whose branch already exists, is left alone.

The pull request is a draft because the new version may break the consumer, and the fixes belong
on that branch: the pull request that fixes the breakage carries the bump. Its first paragraph is
written for users, since it becomes part of the consumer's next release notes; the instructions
to the maintainer are an HTML comment, which the notes drop.

Writing to another repository needs a token the release job does not have: its own
`GITHUB_TOKEN` is scoped to the repository being released. Store a fine-grained personal access
token with **Contents** and **Pull requests** write access to the consumers as the repository
secret `PROPAGATE_TOKEN` in each repository with an `etc/downstream`, and pass it through in
`.github/workflows/release.yml` with `secrets: inherit`. Without it the release is published as
before and the job says that nothing was proposed; a failure to propose never fails a release,
since by then it is public. `RELEASE_DRY_RUN=1` prints the diff each pull request would make.
xek's runner release runs the same script from the releasing machine, with `--xek` and the
builder script's SHA-256, using whatever `gh` is authenticated as there.

### The notes

Every release's notes are assembled by `release_notes.py`, from: a lead paragraph; the
repository's `doc/notes/<version>.md`, verbatim, if it has committed one (optional everywhere,
with no gate); an install section, for an application; **Changes**, one entry per pull request
merged since the previous release tag, taking the title, the summary paragraph and the
user-facing notes from the pull request body — which is what `pull_request_template.md` has been
asking every PR for all along; a **Migration** section, where the repository keeps migration
notes; and an **Assets** section saying what is attached and how to pin it.

The generator can be run by hand against an already-published version, which is the cheapest way
to iterate on the format.
