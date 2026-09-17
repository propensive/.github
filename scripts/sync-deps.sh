#!/usr/bin/env bash
#
# Install every library pinned in etc/refs — and, transitively, everything those pins were
# built against — into the local ivy repository (`~/.ivy2/local`, which coursier and so Mill
# consult by default), so the build resolves exactly the pinned jars. This is what the shared
# CI workflow runs before building, and `make sync-deps` locally.
#
# See deps.py for the file's format and the transitive rule. A release is installed from its
# GitHub Release; a snapshot from its `snapshot-<hex>` pre-release (published by snapshot.sh).
# A snapshot that is NOT on GitHub — pinned from a local commit before anyone published it — is
# built here instead, when a sibling checkout of the repository holding the pinned commit is
# found at `$PROPENSIVE_WORK/<name>` (default: next to this repository): the commit is checked
# out in a throwaway worktree, its filtered tree is checked against the pin, and its own
# `make snapshot LOCAL=1` stages and installs the jars. Otherwise the pin is an error naming the
# `make snapshot` that would publish it.
#
# Both paths install the same bytes a consumer's CI resolves; both overwrite what a
# `publishLocal` left under the same version.
#
# Usage: etc/shared sync-deps.sh [file]      (default etc/refs)
#
# Environment: GITHUB_TOKEN lifts the API rate limit; IVY_LOCAL overrides the destination;
# PROPENSIVE_WORK is the directory holding sibling checkouts.

set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

FILE=${1:-etc/refs}
if [[ ! -f "$FILE" ]]; then
  echo "sync-deps: $FILE does not exist" >&2; exit 1
fi

WORK=${PROPENSIVE_WORK:-$(dirname "$ROOT")}

build_snapshot() {
  local repo=$1 version=$2 commit=$3
  local name=${repo##*/}
  local hex=${version##*-}
  local sibling="$WORK/$name"

  if [[ -z "$commit" ]]; then
    echo "sync-deps: $repo has no release tagged snapshot-$hex and the pin names no commit to build it from" >&2
    return 1
  fi
  if [[ ! -d "$sibling/.git" && ! -f "$sibling/.git" ]]; then
    echo "sync-deps: $repo has no release tagged snapshot-$hex and no checkout was found at $sibling" >&2
    echo "sync-deps: run \`make snapshot\` at $commit in a $name checkout, or set PROPENSIVE_WORK" >&2
    return 1
  fi
  if ! git -C "$sibling" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "sync-deps: the checkout at $sibling does not have commit $commit; fetch it first" >&2
    return 1
  fi

  local scratch
  scratch=$(mktemp -d)
  echo "sync-deps: building $repo $version from $sibling at ${commit:0:12}"
  git -C "$sibling" worktree add --detach --quiet "$scratch/src" "$commit"
  (
    cd "$scratch/src"
    local tree
    tree=$("$PROPENSIVE_SHARED" filtered_tree.py HEAD)
    if [[ "${tree:0:12}" != "$hex" ]]; then
      echo "sync-deps: commit ${commit:0:12} of $repo has filtered tree ${tree:0:12}, not $hex; the pin is inconsistent" >&2
      exit 1
    fi
    LOCAL=1 make snapshot
    ./mill shutdown >/dev/null 2>&1 || true
  )
  local status=$?
  git -C "$sibling" worktree remove --force "$scratch/src" || true
  rm -rf "$scratch"
  return $status
}

count=0
while IFS=$'\t' read -r repo version tag kind commit; do
  [[ -z "$repo" ]] && continue
  count=$((count + 1))
  status=0
  "$PROPENSIVE_SHARED" sync_releases.py --repo "$repo" --tag "$tag" || status=$?
  if [[ $status -eq 3 && "$kind" == "snapshot" ]]; then
    build_snapshot "$repo" "$version" "${commit:-}"
  elif [[ $status -ne 0 ]]; then
    exit $status
  fi
done < <("$PROPENSIVE_SHARED" deps.py walk "$FILE")

echo "sync-deps: $count pins installed, transitively, from $FILE"
