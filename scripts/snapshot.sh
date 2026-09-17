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
if (( ${#jars[@]} == 0 )); then
  echo "snapshot: release.stage produced no jars" >&2; exit 1
fi
for jar in "${jars[@]}"; do
  if [[ "$(basename "$jar")" != *"-$VERSION.jar" ]]; then
    echo "snapshot: staged jar $(basename "$jar") does not carry $VERSION; does build.mill read ${UPPER}_RELEASE_VERSION through Task.env?" >&2
    exit 1
  fi
done
echo "snapshot: staged ${#jars[@]} jars"

# Installed locally first, from the staged directory, so this checkout and every consumer on
# this machine resolve the same bytes the pre-release will hold.
"$PROPENSIVE_SHARED" sync_releases.py --staged "$STAGE_DIR"

if [[ "$LOCAL" == 1 ]]; then
  echo "snapshot: installed locally only (LOCAL=1); not published"
elif gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "snapshot: $REPO already has $TAG; nothing to upload"
else
  notes="Snapshot $VERSION of $NAME, built from $COMMIT (filtered tree $TREE): the library jars \
of an UNRELEASED build, each with its POM and ivy.xml embedded, for a dependent repository to pin \
in its etc/refs until $NAME is released. Not for use as a release; it may be deleted once \
nothing pins it."
  gh release create "$TAG" --repo "$REPO" --prerelease --target "$COMMIT" \
    --title "$NAME snapshot $HEX" --notes "$notes" "${jars[@]}" >/dev/null
  echo "snapshot: uploaded ${#jars[@]} jars to $TAG"

  # GitHub computes each asset's SHA-256 shortly after upload; wait for them all and confirm
  # each is the digest of the local file, since that is what a consumer will verify against.
  # Through the REST API, as release-launcher.sh does: `gh release view --json assets` does
  # not expose the digest.
  for jar in "${jars[@]}"; do
    name=$(basename "$jar")
    local_digest=$(shasum -a 256 "$jar" | cut -d' ' -f1)
    digest=""
    for i in $(seq 1 60); do
      digest=$(gh api "repos/$REPO/releases/tags/$TAG" \
        --jq ".assets[] | select(.name == \"$name\") | .digest // \"\"" 2>/dev/null || true)
      [[ -n "$digest" ]] && break
      sleep 5
    done
    if [[ "$digest" != "sha256:$local_digest" ]]; then
      echo "snapshot: GitHub's digest '$digest' for $name does not match local sha256:$local_digest" >&2
      exit 1
    fi
  done
  echo "snapshot: every asset's digest matches"
fi

echo "snapshot: pin it in a consumer's etc/refs as:"
printf '%s\t%s\t%s\n' "$REPO" "$VERSION" "$COMMIT"
