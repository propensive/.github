#!/usr/bin/env bash
#
# Publish the tagged version of this repository to GitHub Releases. One implementation for every
# Soundness-ecosystem repository, replacing the three that preceded it (release-launcher.sh here,
# and etc/ci/release.sh in Soundness and Pyrocosm).
#
# A release is cut by tagging — `git tag -s X.Y.Z && git push --tags` — which fires the caller's
# .github/workflows/release.yml, which calls scala-release.yml in this repository, which runs this
# script through etc/shared at the commit pinned in etc/github-ref. The tag therefore exists
# BEFORE anything is built: it is the trigger, not the last step, which is the one substantive
# difference from the scripts this replaces.
#
# Usage: etc/shared release.sh [X.Y.Z]      the version defaults to $GITHUB_REF_NAME
#
# Everything that varies between repositories is declared in the caller's `etc/release`, one
# `key<TAB>value` line each (a run of spaces separates them just as well, so the file can be
# aligned), `#` for comments:
#
#   name       the repository and application name; `propensive/<name>`, and <NAME>_RELEASE_VERSION
#   title      the release title prefix — `flair`, but `Soundness`
#   build      mill targets run, in order, before `release.stage`
#   launcher   the launcher module, when executables are published; absent for a library
#   hints      the `--github` publication homes Burdock matches the classpath against
#   probes     modules whose `publishVersion` must equal the tag before anything is published
#   migration  the migration-notes directory, when the repository keeps them
#   verify     an extra gate command; may be repeated, and each is run in order
#
# Two things are deliberately NOT declared, because they can be derived: the library list (the
# filenames `release.stage` produces) and the version pin (`val <name>Version` in build.mill).
#
# Environment: GITHUB_TOKEN authenticates `gh` and lifts the API rate limit; RELEASE_REPO
# overrides `propensive/<name>`; RELEASE_DRY_RUN=1 runs every gate, builds, stages and prints the
# notes without publishing, deleting or uploading anything; PROPAGATE_TOKEN, a token with write
# access to the repositories named in `etc/downstream`, lets the published release be proposed to
# them (see propagate.py) — without it, nothing is proposed and the release is unaffected.
#
# Requires: `gh`, authenticated with contents write access to the repository.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

CONFIG=etc/release
DRY_RUN=${RELEASE_DRY_RUN:-0}

fail() { echo "release: $1" >&2; exit 1; }
note() { echo "release: $1" >&2; }

[[ -f "$CONFIG" ]] || fail "$CONFIG does not exist; this repository is not set up for releases"

# ---------------------------- CONFIGURATION ----------------------------

# `read -r key value` splits on the first run of whitespace and keeps the rest verbatim, so a
# value may contain spaces (`build` and `probes` are lists) and the file may be tab- or
# space-aligned. A key may repeat: every value is printed, in order.
config() {
  local want=$1 key value
  while read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" == "$want" ]] && printf '%s\n' "$value"
  done < "$CONFIG"
  # Explicitly: the loop ends on the `read` that hits EOF, whose status is 1, and `set -e` would
  # otherwise kill the script at the first `NAME=$(config name)`. An absent key is not an error.
  return 0
}

# A typo in a key would otherwise be silently ignored — and a mistyped `migration` or `probes`
# silently drops a gate, which is exactly the kind of failure a release must not have.
KNOWN=" name title build launcher hints probes migration verify "
while read -r key _; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  [[ "$KNOWN" == *" $key "* ]] || fail "$CONFIG: unknown key '$key'"
done < "$CONFIG"

NAME=$(config name)
TITLE=$(config title)
[[ -n "$NAME" ]] || fail "$CONFIG: no 'name'"
[[ -n "$TITLE" ]] || TITLE=$NAME
LAUNCHER=$(config launcher)
HINTS=$(config hints)
MIGRATION=$(config migration)
UPPER=$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_')
REPO=${RELEASE_REPO:-propensive/$NAME}

VERSION=${1:-${GITHUB_REF_NAME:-}}
[[ -n "$VERSION" ]] || fail "no version given and GITHUB_REF_NAME is unset"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$VERSION' is not of the form X.Y.Z"

note "$TITLE $VERSION from $REPO$([[ "$DRY_RUN" == 1 ]] && echo ' (dry run)')"

# ---------------------------- PHASE A: GATES ----------------------------
#
# Nothing has been published yet, so a failure here simply exits: the tag stays, and the fix is
# a new commit and a re-tag. Past this phase the rollback trap below is armed.

command -v gh >/dev/null 2>&1 || fail "the GitHub CLI (gh) is required"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

if [[ -n "$(git status --porcelain)" ]]; then
  # Always clean in the workflow, which checks out the tag; a dry run is a rehearsal, and is
  # often wanted with the change still uncommitted.
  [[ "$DRY_RUN" == 1 ]] || fail "the working tree is not clean"
  note "dry run: the working tree is not clean; a real release would stop here"
fi

HEAD_SHA=$(git rev-parse HEAD)

# The tag must exist on the remote and name this commit. In the workflow it does by construction.
# A dry run is most useful BEFORE the tag exists — rehearsing the release about to be cut — so
# there the tag gates are reported as skipped rather than failing.
# On a 404 `gh api` writes the error body to stdout and exits non-zero, so the absence of the tag
# is read from the status, never from the output being empty.
if ! REMOTE_TAG=$(gh api "repos/$REPO/git/ref/tags/$VERSION" \
     --jq '.object.sha + " " + .object.type' 2>/dev/null); then
  REMOTE_TAG=""
fi

if [[ -z "$REMOTE_TAG" ]]; then
  [[ "$DRY_RUN" == 1 ]] || fail "$REPO has no tag $VERSION; push it with \`git push --tags\`"
  note "dry run: $REPO has no tag $VERSION yet, so the tag gates are skipped"
else
  TAG_OBJECT=${REMOTE_TAG%% *}
  TAG_TYPE=${REMOTE_TAG##* }

  # An annotated tag points at a tag object which points at the commit; a lightweight tag points
  # at the commit directly — and cannot carry a signature, so it fails the next check anyway.
  if [[ "$TAG_TYPE" == "tag" ]]; then
    TAGGED_SHA=$(gh api "repos/$REPO/git/tags/$TAG_OBJECT" --jq .object.sha)
    VERIFIED=$(gh api "repos/$REPO/git/tags/$TAG_OBJECT" --jq '.verification.verified')
  else
    TAGGED_SHA=$TAG_OBJECT
    VERIFIED=false
  fi

  [[ "$TAGGED_SHA" == "$HEAD_SHA" ]] ||
    fail "tag $VERSION names ${TAGGED_SHA:0:12}, but this is ${HEAD_SHA:0:12}"

  if [[ "$VERIFIED" != "true" ]]; then
    echo "release: tag $VERSION is not a verified signed tag." >&2
    echo "  Tag with \`git tag -s $VERSION\` — a lightweight tag carries no signature — and make" >&2
    echo "  sure the signing key is uploaded to the GitHub account that owns it. Soundness signs" >&2
    echo "  its tags with a PGP key, which is separate from its SSH attestation key; GitHub" >&2
    echo "  verifies only keys it has been given." >&2
    exit 1
  fi
  note "tag $VERSION is signed and verified, at ${HEAD_SHA:0:12}"
fi

# The gate is a CI run that has already passed on this exact commit — the release does not re-run
# the suite. Runs of the release workflow itself are excluded, so that a rolled-back first
# attempt does not block the retry on the same commit.
if ! RUNS=$(gh api "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100" \
     --jq '.workflow_runs[] | select(.path != ".github/workflows/release.yml")
           | [.name, .status, (.conclusion // "-")] | @tsv' 2>/dev/null); then
  fail "could not read the CI runs for ${HEAD_SHA:0:12} from $REPO"
fi
[[ -n "$RUNS" ]] || fail "no CI run on ${HEAD_SHA:0:12}; a release is cut from a commit CI has passed"

successes=0
while IFS=$'\t' read -r run_name status conclusion; do
  [[ -z "$run_name" ]] && continue
  case "$status:$conclusion" in
    completed:success)                 successes=$((successes + 1)) ;;
    completed:skipped|completed:neutral) ;;
    completed:*) fail "the '$run_name' run on ${HEAD_SHA:0:12} concluded $conclusion" ;;
    *)           fail "the '$run_name' run on ${HEAD_SHA:0:12} is still $status; wait for CI" ;;
  esac
done <<< "$RUNS"
(( successes > 0 )) || fail "no CI run on ${HEAD_SHA:0:12} succeeded"
note "CI is green on ${HEAD_SHA:0:12} ($successes successful run(s))"

if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  [[ "$DRY_RUN" == 1 ]] || fail "$REPO already has a release $VERSION"
  note "dry run: $REPO already has a release $VERSION; nothing here will touch it"
fi

# The version the build compiles into its POMs — and, in a launcher repository, the fixed
# coordinate at which the launcher resolves its own libraries — must be the version being
# released. Soundness has no such `val` (its publishVersion comes from the tag), so an empty
# result means the check does not apply rather than that it failed.
PINNED=$(sed -n "s/.*val ${NAME}Version = \"\\(.*\\)\".*/\\1/p" build.mill)
if [[ -n "$PINNED" && "$PINNED" != "$VERSION" ]]; then
  fail "build.mill pins ${NAME}Version=$PINNED, not $VERSION; bump it, merge, and re-tag"
fi

# The migration notes must be finalised for this version: the release PR renames pending.md to
# <version>.md, and the first change after the release starts a new pending.md. A surviving
# pending.md means that PR has not merged, so the tag names a commit whose notes are unreleased.
if [[ -n "$MIGRATION" ]]; then
  [[ ! -e "$MIGRATION/pending.md" ]] ||
    fail "$MIGRATION/pending.md still exists; rename it to $MIGRATION/$VERSION.md and merge that first"
  [[ -f "$MIGRATION/$VERSION.md" ]] ||
    fail "$MIGRATION/$VERSION.md is missing; the migration notes for $VERSION must be committed before tagging"
  note "migration notes for $VERSION are in place"
fi

while read -r command; do
  [[ -z "$command" ]] && continue
  note "gate: $command"
  eval "$command" || fail "the gate \`$command\` failed"
done < <(config verify)

# A release may depend only on releases: every pin in etc/refs, transitively, must be a published
# X.Y.Z, and every tool in etc/tools a published release. Then install exactly those, so the
# build compiles against the released jars and not against an earlier snapshot under the same
# version.
"$PROPENSIVE_SHARED" deps.py check
"$PROPENSIVE_SHARED" sync-deps.sh

# The `xeq` builder packages the executables. Fetch and verify it before anything is published,
# so a failed download cannot leave a half-made release behind.
if [[ -n "$LAUNCHER" ]]; then
  "$PROPENSIVE_SHARED" xeq-fetch.sh
fi

# ---------------------------- ROLLBACK ----------------------------
#
# From here the tag can become a release, so a failure must undo both. Deleting the remote tag is
# what makes a retry clean: `git tag -d X && git tag -s X && git push --tags` after the fix.

published=""

rollback() {
  local status=$?
  (( status == 0 )) && return 0
  [[ "$DRY_RUN" == 1 ]] && return 0

  local left=""

  if [[ -n "$published" ]]; then
    if gh release delete "$VERSION" --repo "$REPO" --yes >/dev/null 2>&1; then
      echo "release: deleted the release $VERSION" >&2
    else
      left="the release"
      echo "release: COULD NOT delete the release $VERSION; delete it by hand" >&2
    fi
  fi

  if gh api -X DELETE "repos/$REPO/git/refs/tags/$VERSION" >/dev/null 2>&1; then
    echo "release: deleted the tag $VERSION from $REPO" >&2
  else
    left="${left:+$left and }the tag"
    echo "release: COULD NOT delete the tag $VERSION; delete it with" >&2
    echo "  git push --delete origin $VERSION" >&2
  fi

  if [[ -n "$left" ]]; then
    echo "release: rolled back, but $left could not be removed — see above." >&2
  else
    echo "release: rolled back; nothing is published and the tag is gone from origin." >&2
  fi
  echo "release: fix, then: git tag -d $VERSION && git tag -s $VERSION && git push --tags" >&2
}

trap rollback EXIT

# ---------------------------- PHASE B: BUILD AND STAGE ----------------------------

# The single source of truth for the version, read by `publishVersion` (a `Task.Input`, so a
# running Mill daemon sees this export) in every repository's build.mill.
export "${UPPER}_RELEASE_VERSION=$VERSION"

while read -r targets; do
  [[ -z "$targets" ]] && continue
  for target in $targets; do
    note "building $target"
    ./mill "$target" || fail "building $target failed"
  done
done < <(config build)

# Every released module must resolve to exactly this version before anything leaves the machine.
# The env var makes all modules resolve identically, so a handful of probes suffice.
while read -r modules; do
  [[ -z "$modules" ]] && continue
  for module in $modules; do
    resolved=$(./mill show "$module.publishVersion" | tr -d '"')
    [[ "$resolved" == "$VERSION" ]] ||
      fail "$module.publishVersion=$resolved, expected $VERSION"
  done
done < <(config probes)

# `release.stage` builds every released jar into one directory under its release asset name, with
# its POM and ivy.xml embedded under META-INF/maven/ — the jar alone is then enough for a
# consumer's sync-deps.sh to rebuild a resolvable local repository.
./mill release.stage || fail "staging the release jars failed"

STAGE_DIR="out/release/stage.dest"
mapfile -t jars < <(find "$STAGE_DIR" -maxdepth 1 -name '*.jar' | sort)
count=${#jars[@]}
(( count > 0 )) || fail "release.stage produced no jars"

LIBRARIES=""
for jar in "${jars[@]}"; do
  base=$(basename "$jar")
  [[ "$base" == *"-$VERSION.jar" ]] || fail "staged jar $base does not carry version $VERSION"
  LIBRARIES="$LIBRARIES ${base%-"$VERSION".jar}"
done
LIBRARIES=${LIBRARIES# }
note "staged $count jars for $VERSION"

# Installed over whatever publishLocal left, so that a launcher's compile classpath holds exactly
# the bytes being released — which is what Burdock hashes and matches against the release assets.
"$PROPENSIVE_SHARED" sync_releases.py --staged "$STAGE_DIR"

export RELEASE_NAME="$NAME" RELEASE_TITLE="$TITLE" RELEASE_REPO_NAME="$REPO" \
       RELEASE_LIBRARIES="$LIBRARIES" RELEASE_LAUNCHER="$LAUNCHER" RELEASE_MIGRATION="$MIGRATION"

if [[ "$DRY_RUN" == 1 ]]; then
  note "dry run: nothing will be published. The notes would be:"
  echo
  "$PROPENSIVE_SHARED" release_notes.py "$VERSION"
  echo
  # What the release would propose to its consumers, read from GitHub but written nowhere.
  "$PROPENSIVE_SHARED" propagate.py --dry-run "$VERSION" ||
    note "dry run: previewing the pull requests to consumers failed"
  note "dry run complete: $count jars staged ($LIBRARIES)"
  trap - EXIT
  exit 0
fi

# ---------------------------- PHASE C: PUBLISH ----------------------------
#
# Two paths, and the asymmetry between them is inherent. A library repository publishes a DRAFT
# and only makes it visible once every asset's digest has been checked, so nothing partial is
# ever seen. A launcher repository cannot: the repackaged executables externalize each library by
# matching its SHA-256 against the release's PUBLISHED assets, and a draft's asset URLs live
# under an `untagged-…` path that changes when the draft is published, which would bake dead URLs
# into the executables. So its release is made in two steps, exactly as it must be consumed.

# Every asset's digest, as `<name> sha256:<hex>` lines, for the release id in `$1`.
#
# ONE paginated request for the whole list, not one per asset: Soundness attaches six hundred
# jars, and polling each separately is six hundred requests returning the same payload — minutes
# of latency, and enough write-adjacent traffic to trip the very secondary rate limit the uploads
# just survived. The dedicated assets endpoint paginates properly; the release object's own
# `assets` array does not.
#
# GitHub computes the digests asynchronously, so poll until none is blank, then let the caller
# compare them all locally.
release_digests() {
  local out=""
  for _ in $(seq 1 60); do
    out=$(gh api "repos/$REPO/releases/$1/assets?per_page=100" --paginate \
      --jq '.[] | .name + " " + (.digest // "")' 2>/dev/null || true)
    if [[ -n "$out" ]] && ! grep -q ' $' <<< "$out"; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 5
  done
  printf '%s\n' "$out"
  return 1
}

# Checks every staged jar against the digest GitHub recorded for it. `$1` is the release id.
verify_digests() {
  local listing name local_digest got
  listing=$(release_digests "$1") ||
    fail "GitHub had not computed every asset digest within five minutes of upload"

  declare -A remote=()
  while read -r name got; do
    [[ -n "$name" ]] && remote["$name"]=$got
  done <<< "$listing"

  for jar in "${jars[@]}"; do
    name=$(basename "$jar")
    local_digest=$(shasum -a 256 "$jar" | cut -d' ' -f1)
    got=${remote[$name]:-}
    [[ -n "$got" ]] || fail "the release has no asset named $name"
    [[ "$got" == "sha256:$local_digest" ]] ||
      fail "released digest '$got' for $name does not match local sha256:$local_digest"
  done
  note "every asset's digest matches ($count checked in one request)"
}

# Uploads one batch, retrying a transient failure rather than discarding the build.
#
# GitHub applies a SECONDARY rate limit to asset uploads, which six hundred jars reach in under a
# minute — it is what stopped the first 0.68.0 release at jar 451 of 626, after a fifteen-minute
# build. The limit is explicitly temporary ("wait a few minutes"), so the batch is retried with
# growing backoff; `--clobber` makes a retry idempotent, so re-sending a batch that partly landed
# is safe. Stderr is left attached, so the 403 is visible in the log.
upload_batch() {
  local attempt delay attempts=5
  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    if gh release upload "$VERSION" --repo "$REPO" --clobber "$@" >/dev/null; then
      return 0
    fi
    if (( attempt == attempts )); then
      note "upload attempt $attempt of $attempts failed; giving up"
      return 1
    fi
    delay=$((60 * attempt))
    note "upload attempt $attempt of $attempts failed; retrying in ${delay}s"
    sleep "$delay"
  done
  return 1
}

if [[ -z "$LAUNCHER" ]]; then

  gh release create "$VERSION" --repo "$REPO" --draft --title "$TITLE $VERSION" \
    --notes "Publishing…" >/dev/null || fail "could not create the draft release"
  published="draft"

  # In batches, so each API session is short enough to retry cheaply; `--clobber` makes a
  # retried batch idempotent. Soundness attaches some six hundred jars.
  batch=50
  for (( start = 0; start < count; start += batch )); do
    upload_batch "${jars[@]:start:batch}" ||
      fail "uploading jars $((start + 1))-$(( start + batch > count ? count : start + batch )) failed after five attempts"
    note "uploaded $(( start + batch > count ? count : start + batch ))/$count jars"
    # Paced so the common case never reaches the secondary limit in the first place; the retry
    # above is the safety net, not the plan. Skipped after the final batch.
    (( start + batch < count )) && sleep 10
  done

  # By release id through the REST API: `gh release view --json assets` does not expose the
  # digest, and `releases/tags/<tag>` serves only published releases — this one is still a draft.
  RELEASE_ID=$(gh api "repos/$REPO/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$VERSION\" and .draft) | .id" | head -1)
  [[ "$RELEASE_ID" =~ ^[0-9]+$ ]] || fail "could not find the draft release $VERSION through the API"

  verify_digests "$RELEASE_ID"

  uploaded=$(gh api "repos/$REPO/releases/$RELEASE_ID/assets?per_page=100" --paginate --jq '.[].name' | wc -l | tr -d ' ')
  [[ "$uploaded" == "$count" ]] ||
    fail "the draft release has $uploaded assets but $count jars were staged"

  NOTES=$(mktemp)
  "$PROPENSIVE_SHARED" release_notes.py "$VERSION" > "$NOTES" || fail "generating the notes failed"
  [[ -s "$NOTES" ]] || fail "the generated notes are empty"
  gh release edit "$VERSION" --repo "$REPO" --notes-file "$NOTES" >/dev/null ||
    fail "could not write the release notes"
  gh release edit "$VERSION" --repo "$REPO" --draft=false >/dev/null ||
    fail "could not publish the draft"

else

  # Step 1: the release, with the library jars alone — the exact bytes the local publish put on
  # the launcher's compile classpath, so the digests GitHub records are the hashes Burdock
  # computed at compile time.
  gh release create "$VERSION" --repo "$REPO" --title "$TITLE $VERSION" \
    --notes "Publishing…" "${jars[@]}" >/dev/null || fail "could not create the release"
  published="yes"

  RELEASE_ID=$(gh api "repos/$REPO/releases/tags/$VERSION" --jq .id)
  verify_digests "$RELEASE_ID"

  # Step 2: the launcher, repackaged against the now-published libraries. The `burdock.externalize`
  # macro embedded META-INF/burdock.deps at compile time; the repackager rewrites the JAR in place
  # so that published dependencies become on-demand `Burdock-Require` URLs.
  # `clean` first, and not because `out/` might be warm from a previous run — it never is here.
  # The launcher depends on its libraries at a FIXED coordinate, and `sync_releases.py --staged`
  # has just replaced those jars in ~/.ivy2/local under that same version, in this very run;
  # Mill's cached resolution would not notice, and the assembly would silently bundle whatever
  # was resolved before.
  ./mill clean "$LAUNCHER" >/dev/null
  ./mill "$LAUNCHER.assembly" || fail "assembling $LAUNCHER failed"
  cp "out/$(echo "$LAUNCHER" | tr '.' '/')/assembly.dest/out.jar" "$NAME.jar"
  java -cp "$NAME.jar" soundness.repackage --github "$HINTS" | tee "/tmp/$NAME-repackage.log"

  # The whole point of the two-step ordering: refuse to ship an executable that quietly inlined a
  # library instead of referring to the release.
  for lib in $LIBRARIES; do
    grep -q "propensive/$NAME/releases/download/$VERSION/$lib-$VERSION.jar" \
      "/tmp/$NAME-repackage.log" ||
      fail "$lib did not externalize against this release; not uploading the executables"
  done

  # An XEQ executable is a bare runner stub, a configuration record and the platform-independent
  # repackaged JAR joined end to end — not compiled — so one machine cross-"builds" every platform.
  PLATFORMS="linux-x64 linux-arm64 macos-x64 macos-arm64 windows-x64"
  DIST=$(mktemp -d)
  for platform in $PLATFORMS; do
    ext=""; [[ "$platform" == windows-* ]] && ext=".exe"
    dist/xeq build --jar "$NAME.jar" --out "$DIST/$NAME-$platform$ext" --target "$platform" ||
      fail "building the $platform executable failed"
  done
  gh release upload "$VERSION" --repo "$REPO" "$DIST"/"$NAME"-* >/dev/null ||
    fail "uploading the executables failed"

  # The `<name>` polyglot bootstrap: a small any-shell script embedding each executable's URL and
  # checksum, which downloads the right one, verifies it, replaces itself and re-invokes.
  MANIFEST=$(mktemp)
  for _ in $(seq 1 60); do
    gh api "repos/$REPO/releases/$RELEASE_ID" --jq \
      ".assets[] | select((.name | startswith(\"$NAME-\")) and (.name | endswith(\".jar\") | not))
       | .name + \"\\t\" + .browser_download_url + \"\\t\" + (.digest // \"\" | sub(\"sha256:\"; \"\"))" \
      > "$MANIFEST"
    grep -qv $'\t$' "$MANIFEST" && ! grep -q $'\t$' "$MANIFEST" && break
    sleep 5
  done
  sed -i.bak "s/^$NAME-//; s/\\.exe\t/\t/" "$MANIFEST"
  dist/xeq dispatch --out "$DIST/$NAME" --manifest "$MANIFEST" || fail "building the dispatcher failed"
  gh release upload "$VERSION" --repo "$REPO" "$DIST/$NAME" >/dev/null ||
    fail "uploading the dispatcher failed"

  # The installer served from https://propensive.dev/<name>, which redirects to this asset;
  # it embeds this release's per-platform digests, so it is generated once they are all known.
  "$PROPENSIVE_SHARED" generate-install.sh "$NAME" "$VERSION" > "$DIST/install.sh" ||
    fail "generating install.sh failed"
  gh release upload "$VERSION" --repo "$REPO" "$DIST/install.sh" >/dev/null ||
    fail "uploading install.sh failed"

  NOTES=$(mktemp)
  "$PROPENSIVE_SHARED" release_notes.py "$VERSION" > "$NOTES" || fail "generating the notes failed"
  [[ -s "$NOTES" ]] || fail "the generated notes are empty"
  gh release edit "$VERSION" --repo "$REPO" --notes-file "$NOTES" >/dev/null ||
    fail "could not write the release notes"

fi

trap - EXIT
note "$VERSION published to https://github.com/$REPO/releases/tag/$VERSION ($count jars)"

# Propose the release to the repositories that consume it, one draft pull request each. This runs
# after the rollback trap is disarmed and never fails the job: the release is already public, and
# a consumer that could not be reached is a pull request to open by hand, not a release to undo.
"$PROPENSIVE_SHARED" propagate.py "$VERSION" ||
  note "proposing $VERSION to its consumers failed; open those pull requests by hand"
