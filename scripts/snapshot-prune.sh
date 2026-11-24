#!/usr/bin/env bash
#
# Delete this repository's snapshot pre-releases (see snapshot.sh) older than a number of days,
# with their tags. Snapshots exist only to be pinned until the next release; nothing checks
# whether one is still pinned somewhere, so keep the horizon longer than any branch you expect
# to leave unmerged. A consumer whose pin has been pruned gets a clear error from sync-deps.sh
# and can rebuild it from the pinned commit.
#
# Usage: etc/shared snapshot-prune.sh <name> [days]     (default 60)
# Requires `gh` authenticated with push access to propensive/<name>.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <name> [days]" >&2; exit 1
fi
REPO="propensive/$1"
DAYS=${2:-60}
CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)

mapfile -t stale < <(gh release list --repo "$REPO" --limit 1000 \
  --json tagName,isPrerelease,createdAt \
  --jq ".[] | select(.isPrerelease and (.tagName | startswith(\"snapshot-\")) and .createdAt < \"$CUTOFF\") | .tagName")

if (( ${#stale[@]} == 0 )); then
  echo "snapshot-prune: no snapshots of $REPO older than $DAYS days"; exit 0
fi
# A request to GitHub, tried again if it fails: a server error or a rate limit passes.
attempt() {
  local try
  for (( try = 1; try <= 5; try++ )); do
    "$@" >/dev/null 2>&1 && return 0
    (( try == 5 )) || sleep $((10 * try))
  done
  return 1
}

# Whether the release of a tag is still there.
released() { gh api "repos/$REPO/releases/tags/$1" --jq .id 2>/dev/null; }

# A snapshot of a large repository has hundreds of assets, and GitHub can fail to delete such a
# release in the time it allows one request ("HTTP 502: Server Error", of a Soundness snapshot
# with 626). Its assets are then deleted one at a time, each a request GitHub can answer, and
# the release, now empty, after them. Run again, this carries on from where it stopped.
prune() {
  local tag=$1 id asset
  if gh release delete "$tag" --repo "$REPO" --cleanup-tag --yes 2>/dev/null; then return 0; fi

  # The request may have failed and the deletion happened all the same.
  sleep 5
  id=$(released "$tag") || id=""
  if [[ -n "$id" ]]; then
    echo "snapshot-prune: GitHub would not delete $tag whole; deleting its assets first"
    while true; do
      mapfile -t assets < <(gh api "repos/$REPO/releases/$id/assets?per_page=100" --jq '.[].id')
      (( ${#assets[@]} > 0 )) || break
      for asset in "${assets[@]}"; do
        attempt gh api -X DELETE "repos/$REPO/releases/assets/$asset" ||
          { echo "snapshot-prune: could not delete an asset of $tag; run again to resume" >&2
            return 1; }
      done
    done
    attempt gh api -X DELETE "repos/$REPO/releases/$id" ||
      { echo "snapshot-prune: could not delete the release $tag; run again to resume" >&2
        return 1; }
  fi

  if git ls-remote --exit-code --tags "https://github.com/$REPO.git" "refs/tags/$tag" \
      >/dev/null 2>&1; then
    attempt gh api -X DELETE "repos/$REPO/git/refs/tags/$tag" ||
      { echo "snapshot-prune: could not delete the tag $tag; run again to resume" >&2
        return 1; }
  fi
}

for tag in "${stale[@]}"; do
  prune "$tag"
  echo "snapshot-prune: deleted $tag"
done

# Their descriptors too: each pruned snapshot's `<version>/` directory on the `ivy` branch (see
# snapshot.sh), where the version is `X.Y.Z-<hex>` for the tag `snapshot-<hex>`.
if git ls-remote --exit-code --heads "https://github.com/$REPO.git" ivy >/dev/null 2>&1; then
  dir=$(mktemp -d)
  git clone --quiet --depth 1 --branch ivy "https://github.com/$REPO.git" "$dir"
  removed=0
  for tag in "${stale[@]}"; do
    for version in "$dir"/*-"${tag#snapshot-}"; do
      [[ -d "$version" ]] || continue
      git -C "$dir" rm -rq "$(basename "$version")"
      removed=$((removed + 1))
    done
  done
  if (( removed > 0 )); then
    git -C "$dir" commit --quiet -m "Prune the descriptors of $removed snapshots"
    git -C "$dir" -c credential.helper='!gh auth git-credential' push --quiet origin HEAD:ivy
    echo "snapshot-prune: removed the descriptors of $removed snapshots from the ivy branch"
  fi
  rm -rf "$dir"
fi
