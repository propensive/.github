#!/usr/bin/env bash
#
# Install a library released to GitHub Releases into the local ivy repository (`~/.ivy2/local`,
# which coursier — and so Mill — consults by default), so a build resolves it from the RELEASED
# jars rather than from a local compile. This is what the shared CI workflow does for every
# `extra_releases` pair: Soundness's own `sync_releases.py`, pointed at the library's repository
# through `SOUNDNESS_RELEASE_REPO`. Each released jar carries its POM and ivy.xml under
# `META-INF/maven/`, so the jar is all that is downloaded, and a jar already present with the
# digest GitHub reports is left alone.
#
# The Python script is fetched from the Soundness release the calling repository is built against
# (its `soundnessVersion` pin), and cached, so this needs the network only the first time for a
# given Soundness version. Soundness itself is NOT synced: a Soundness built and published from a
# local checkout is left as it is.
#
# Usage: etc/shared sync-releases.sh <owner/repo> <pin> [X.Y.Z]    the version in build.mill's
#                                                                   `val <pin>` when omitted
#        etc/shared sync-releases.sh <owner/repo> <pin> --staged  the jars of a local
#                                                                   `./mill release.stage`
#
# For example, `etc/shared sync-releases.sh propensive/pyrocosm pyrocosmVersion`. `--staged` is
# how a release candidate is tried in a dependent repository before anything is tagged; the
# published path is how a release is verified afterwards, since it installs the exact bytes a
# consumer will resolve. Both overwrite whatever `publishLocal` installed for the same version.
#
# Environment: GITHUB_TOKEN, if set, lifts the unauthenticated API rate limit; IVY_LOCAL overrides
# the destination.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <owner/repo> <pin> [X.Y.Z | --staged]" >&2; exit 1
fi

REPO=$1
PIN=$2
shift 2

SOUNDNESS=$(grep 'val soundnessVersion' build.mill | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
PINNED=$(grep "val $PIN" build.mill | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)

if [[ -z "$SOUNDNESS" ]]; then
  echo "sync-releases: could not read soundnessVersion from build.mill" >&2; exit 1
fi

SCRIPT="${TMPDIR:-/tmp}/sync_releases-$SOUNDNESS.py"

if [[ ! -f "$SCRIPT" ]]; then
  url="https://raw.githubusercontent.com/propensive/soundness/$SOUNDNESS/etc/ci/sync_releases.py"
  if ! curl -fsSL -o "$SCRIPT" "$url"; then
    rm -f "$SCRIPT"
    echo "sync-releases: could not fetch $url" >&2; exit 1
  fi
fi

if [[ "${1:-}" == "--staged" ]]; then
  exec env SOUNDNESS_RELEASE_REPO="$REPO" python3 "$SCRIPT" "$@"
fi

VERSION="${1:-$PINNED}"
if [[ -z "$VERSION" ]]; then
  echo "sync-releases: no version given, and build.mill has no \`val $PIN\`" >&2; exit 1
fi

exec env SOUNDNESS_RELEASE_REPO="$REPO" python3 "$SCRIPT" "$VERSION"
