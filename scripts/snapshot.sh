#!/usr/bin/env bash
#
# Publish an UNRELEASED build of this repository's libraries as a snapshot, so that a dependent
# repository can pin it in etc/refs (see deps.py) and have its CI build against it before
# anything is released.
#
# A snapshot is named by the filtered tree of HEAD (filtered_tree.py): version
# `<base>-<12 hex>`, under the GitHub pre-release tagged `snapshot-<12 hex>`, so the same
# sources give the same snapshot whatever the commit, and a snapshot that already exists is
# not uploaded again. `<base>` is the version the repository declares for its next release.
#
# Steps: the working tree must be clean (the tree hash names what is committed, so nothing
# else may be in the jars); the jars are staged by `./mill release.stage` with the snapshot
# version driven through `<NAME>_RELEASE_VERSION` (a `Task.Input` in build.mill, so the
# running Mill daemon sees it); the staged jars are installed into ~/.ivy2/local, exactly as
# a consumer's `sync-deps.sh` will install them; then, unless LOCAL=1, they are uploaded and
# their digests checked against GitHub's, as the release scripts do. The last line printed is
# the etc/refs line for a consumer.
#
# Usage: etc/shared snapshot.sh <name> <base X.Y.Z>       for example, from a Makefile:
#        etc/shared snapshot.sh pyrocosm "$(sed -n 's/.*val pyrocosmVersion = .*"\(.*\)").*/\1/p' build.mill)"
#
# Environment: LOCAL=1 stages and installs without publishing (what sync-deps.sh runs when it
# builds a missing snapshot from a sibling checkout); CLEAN=1 runs `./mill clean` first.
# Requires `gh` authenticated with push access to propensive/<name>, unless LOCAL=1.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <name> <base X.Y.Z>" >&2; exit 1
fi

NAME=$1
BASE=$2
UPPER=$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_')
REPO="propensive/$NAME"
LOCAL=${LOCAL:-0}

if ! [[ "$BASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "snapshot: the base version must be X.Y.Z, not '$BASE'" >&2; exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "snapshot: the working tree is not clean; a snapshot is named by what is committed" >&2; exit 1
fi
if [[ "$LOCAL" != 1 ]]; then
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "snapshot: gh is required and must be authenticated (or set LOCAL=1)" >&2; exit 1
  fi
fi

COMMIT=$(git rev-parse HEAD)

# The pre-release is created against the commit, which GitHub must therefore already have: a
# snapshot of an unpushed commit would be one nobody else could trace back to its sources.
if [[ "$LOCAL" != 1 ]] && ! gh api "repos/$REPO/commits/$COMMIT" --silent >/dev/null 2>&1; then
  echo "snapshot: $REPO does not have commit ${COMMIT:0:12}; push the branch first" >&2; exit 1
fi

TREE=$("$PROPENSIVE_SHARED" filtered_tree.py HEAD)
HEX=${TREE:0:12}
VERSION="$BASE-$HEX"
TAG="snapshot-$HEX"
export "${UPPER}_RELEASE_VERSION=$VERSION"

echo "snapshot: $REPO at ${COMMIT:0:12}, filtered tree $TREE → $VERSION"

if [[ "${CLEAN:-0}" == 1 ]]; then ./mill clean >/dev/null; fi
./mill release.stage

STAGE_DIR="out/release/stage.dest"
mapfile -t jars < <(find "$STAGE_DIR" -maxdepth 1 -name '*.jar' | sort)
mapfile -t descriptors < <(find "$STAGE_DIR" -maxdepth 1 -name '*.ivy.xml' | sort)
if (( ${#jars[@]} == 0 )); then
  echo "snapshot: release.stage produced no jars" >&2; exit 1
fi
if (( ${#descriptors[@]} != ${#jars[@]} )); then
  echo "snapshot: release.stage produced ${#jars[@]} jars but ${#descriptors[@]} ivy.xml descriptors; does its stage task emit both?" >&2; exit 1
fi
# The jars are the pre-release's assets; the `<artifactId>-<version>.ivy.xml` descriptors that
# crux (propensive/crux) reads go to the `ivy` branch, as release.sh publishes them.
assets=("${jars[@]}")
for jar in "${jars[@]}"; do
  if [[ "$(basename "$jar")" != *"-$VERSION.jar" ]]; then
    echo "snapshot: staged jar $(basename "$jar") does not carry $VERSION; does build.mill read ${UPPER}_RELEASE_VERSION through Task.env?" >&2
    exit 1
  fi
done
echo "snapshot: staged ${#jars[@]} jars and their descriptors"

# Installed locally first, from the staged directory, so this checkout and every consumer on
# this machine resolve the same bytes the pre-release will hold.
"$PROPENSIVE_SHARED" sync_releases.py --staged "$STAGE_DIR"

if [[ "$LOCAL" == 1 ]]; then
  echo "snapshot: installed locally only (LOCAL=1); not published"
elif [[ "$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id 2>/dev/null || true)" =~ ^[0-9]+$ ]]; then
  # `releases/tags/<tag>` answers only for a PUBLISHED release; a draft left by a failed upload
  # is resumed below instead.
  echo "snapshot: $REPO already has $TAG; nothing to upload"
else
  dir=$(mktemp -d)
  if git ls-remote --exit-code --heads "https://github.com/$REPO.git" ivy >/dev/null 2>&1; then
    git clone --quiet --depth 1 --branch ivy "https://github.com/$REPO.git" "$dir"
  else
    git clone --quiet --depth 1 --no-checkout "https://github.com/$REPO.git" "$dir"
    git -C "$dir" checkout --quiet --orphan ivy
    git -C "$dir" rm -rfq --cached . 2>/dev/null || true
    find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  fi
  mkdir -p "$dir/$VERSION"
  cp "${descriptors[@]}" "$dir/$VERSION/"
  git -C "$dir" add -A "$VERSION"
  # Nothing to commit when a retry finds the descriptors already published.
  if git -C "$dir" diff --cached --quiet; then
    echo "snapshot: the ivy branch already has the ${#descriptors[@]} descriptors"
  else
    git -C "$dir" commit --quiet -m "Descriptors for snapshot $VERSION"
    git -C "$dir" -c credential.helper='!gh auth git-credential' push --quiet origin HEAD:ivy
    echo "snapshot: published ${#descriptors[@]} descriptors to the ivy branch"
  fi

  notes="Snapshot $VERSION of $NAME, built from $COMMIT (filtered tree $TREE): the library jars \
of an UNRELEASED build, each with its POM and ivy.xml embedded, for a dependent repository to pin \
in its etc/refs until $NAME is released. Not for use as a release; it may be deleted once \
nothing pins it."

  # A draft first, then the assets in batches, then published — as release.sh does. One
  # `gh release create` carrying seven hundred assets is a single upload session, which GitHub
  # ends for inactivity (HTTP 408) before Soundness's jars are through, and leaves a draft
  # behind. A draft with this tag is resumed, not skipped: `--clobber` makes re-sending an
  # asset that already landed idempotent, so the batches simply fill the gaps.
  # Runs a gh command, retrying when GitHub answers with a transient error (a 502 or 504 does
  # happen), so that a flaky minute does not end a run that took an hour to stage. Under
  # `set -e` a bare failure would also end the script without a word.
  retry() {
    local attempt attempts=5
    for (( attempt = 1; attempt <= attempts; attempt++ )); do
      if "$@"; then return 0; fi
      if (( attempt == attempts )); then
        echo "snapshot: '$1 $2 $3' failed $attempts times; giving up" >&2; return 1
      fi
      echo "snapshot: '$1 $2 $3' failed; retrying in $((15 * attempt))s" >&2
      sleep $((15 * attempt))
    done
  }

  draft_id() {
    retry gh api "repos/$REPO/releases?per_page=100" --paginate \
      --jq ".[] | select(.tag_name == \"$TAG\" and .draft) | .id" | head -1
  }

  RELEASE_ID=$(draft_id) || { echo "snapshot: could not list $REPO's releases" >&2; exit 1; }
  if [[ "$RELEASE_ID" =~ ^[0-9]+$ ]]; then
    echo "snapshot: resuming the draft $TAG (release $RELEASE_ID)"
  else
    retry gh release create "$TAG" --repo "$REPO" --prerelease --draft --target "$COMMIT" \
      --title "$NAME snapshot $HEX" --notes "$notes" >/dev/null ||
      { echo "snapshot: could not create the draft $TAG" >&2; exit 1; }
    # The list can lag the creation by a few seconds.
    for _ in $(seq 1 12); do
      RELEASE_ID=$(draft_id) || true
      [[ "$RELEASE_ID" =~ ^[0-9]+$ ]] && break
      sleep 5
    done
    [[ "$RELEASE_ID" =~ ^[0-9]+$ ]] || { echo "snapshot: could not find the draft $TAG" >&2; exit 1; }
  fi

  # Uploads one batch, retrying a transient failure (a timeout, or the secondary rate limit
  # asset uploads reach) with growing backoff rather than discarding the build.
  upload_batch() {
    local attempt delay attempts=5
    for (( attempt = 1; attempt <= attempts; attempt++ )); do
      if gh release upload "$TAG" --repo "$REPO" --clobber "$@" >/dev/null; then return 0; fi
      if (( attempt == attempts )); then
        echo "snapshot: upload attempt $attempt of $attempts failed; giving up" >&2; return 1
      fi
      delay=$((60 * attempt))
      echo "snapshot: upload attempt $attempt of $attempts failed; retrying in ${delay}s" >&2
      sleep "$delay"
    done
    return 1
  }

  # Uploads one asset alone, with its own retries: the fallback when a batch keeps failing.
  # `gh` sends a batch's files concurrently, and GitHub ends any stream idle for too long
  # (HTTP 408), so on a slow or uneven uplink one starved file fails a whole batch; a file
  # sent alone has the connection to itself.
  upload_single() {
    local attempt attempts=5
    for (( attempt = 1; attempt <= attempts; attempt++ )); do
      if gh release upload "$TAG" --repo "$REPO" --clobber "$1" >/dev/null; then return 0; fi
      (( attempt == attempts )) && return 1
      echo "snapshot: $(basename "$1") failed to upload; retrying in $((30 * attempt))s" >&2
      sleep $((30 * attempt))
    done
    return 1
  }

  # Only what the draft lacks: a resumed run re-sends nothing that already landed, since
  # `--clobber` would delete and upload it again. An upload GitHub cut short leaves an asset
  # in state `starter`, with the name but no bytes; it is not present, and `--clobber`
  # replaces it.
  present=$(retry gh api "repos/$REPO/releases/$RELEASE_ID/assets?per_page=100" --paginate \
    --jq '.[] | select(.state == "uploaded") | .name' || true)
  pending=()
  for asset in "${assets[@]}"; do
    grep -qxF "$(basename "$asset")" <<< "$present" || pending+=("$asset")
  done
  count=${#pending[@]}
  echo "snapshot: ${#assets[@]} assets staged, $(( ${#assets[@]} - count )) already on $TAG, $count to upload"

  batch=20
  for (( start = 0; start < count; start += batch )); do
    if ! upload_batch "${pending[@]:start:batch}"; then
      echo "snapshot: batch $((start + 1))-$(( start + batch > count ? count : start + batch )) failed as a batch; sending its assets one at a time" >&2
      for asset in "${pending[@]:start:batch}"; do
        upload_single "$asset" ||
          { echo "snapshot: uploading $(basename "$asset") failed after five attempts" >&2; exit 1; }
      done
    fi
    echo "snapshot: uploaded $(( start + batch > count ? count : start + batch ))/$count assets"
    (( start + batch < count )) && sleep 5
  done

  # GitHub computes each asset's SHA-256 shortly after upload; wait for them all, in ONE
  # paginated request rather than one per asset, and confirm each is the digest of the local
  # file, since that is what a consumer will verify against.
  listing=""
  for i in $(seq 1 60); do
    listing=$(gh api "repos/$REPO/releases/$RELEASE_ID/assets?per_page=100" --paginate \
      --jq '.[] | .name + " " + (.digest // "")' 2>/dev/null || true)
    if [[ -n "$listing" ]] && ! grep -q ' $' <<< "$listing"; then break; fi
    sleep 5
  done
  declare -A remote=()
  while read -r name got; do
    [[ -n "$name" ]] && remote["$name"]=$got
  done <<< "$listing"
  for asset in "${assets[@]}"; do
    name=$(basename "$asset")
    local_digest=$(shasum -a 256 "$asset" | cut -d' ' -f1)
    got=${remote[$name]:-}
    if [[ -z "$got" ]]; then
      echo "snapshot: GitHub has no digest for $name (the asset is missing, or its upload was cut short); run again to resume" >&2
      exit 1
    elif [[ "$got" != "sha256:$local_digest" ]]; then
      echo "snapshot: GitHub's digest '$got' for $name does not match local sha256:$local_digest" >&2
      exit 1
    fi
  done
  uploaded=$(printf '%s\n' "$listing" | grep -c . || true)
  if [[ "$uploaded" != "${#assets[@]}" ]]; then
    echo "snapshot: the draft has $uploaded assets but ${#assets[@]} were staged" >&2; exit 1
  fi
  echo "snapshot: every asset's digest matches"

  retry gh release edit "$TAG" --repo "$REPO" --draft=false >/dev/null ||
    { echo "snapshot: could not publish the draft $TAG" >&2; exit 1; }
  echo "snapshot: published $TAG"
fi

echo "snapshot: pin it in a consumer's etc/refs as:"
printf '%s\t%s\t%s\n' "$REPO" "$VERSION" "$COMMIT"
