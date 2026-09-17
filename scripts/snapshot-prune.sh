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
for tag in "${stale[@]}"; do
  gh release delete "$tag" --repo "$REPO" --cleanup-tag --yes
  echo "snapshot-prune: deleted $tag"
done
