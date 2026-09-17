#!/usr/bin/env bash
#
# Install the commands this repository runs, at the versions pinned in etc/tools (see deps.py):
# each is an application released from propensive/<name> with an `install.sh` asset — the
# installer https://propensive.dev/<name> serves — which downloads the executable for this
# machine, verifies its digest and puts it on the path. A tool whose release has no installer
# (a compiler plugin, say) is a jar, installed by sync-deps.sh instead, and is skipped here.
#
# Usage: etc/shared tools.sh          (or `make tools`)
#
# Environment: the installers honour their own (PREFIX, for one); see each release's notes.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

installed=0
while IFS=$'\t' read -r repo version; do
  [[ -z "$repo" ]] && continue
  name=${repo##*/}
  url="https://github.com/$repo/releases/download/$version/install.sh"
  if ! curl -fsSL -o "/tmp/$name-install-$version.sh" "$url" 2>/dev/null; then
    echo "tools: $repo $version has no install.sh; a jar-only tool, left to sync-deps.sh"
    continue
  fi
  echo "tools: installing $name $version"
  sh "/tmp/$name-install-$version.sh"
  installed=$((installed + 1))
done < <("$PROPENSIVE_SHARED" deps.py tools)

echo "tools: $installed commands installed from etc/tools"
