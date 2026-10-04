#!/usr/bin/env bash
#
# Fetch the pinned `xek` builder into dist/xek, verified against etc/xek.tsv.
#
# `xek` is the single implementation of the XEK executable format, published from
# propensive/xek (formerly propensive/xeq) with the runner stubs. Applications shell out to it to
# package their executables rather than carrying a copy of their own; each repository pins the
# version and the builder's SHA-256 in its own etc/xek.tsv, so this script can be shared while the
# pin stays local. Releases from 1.0.0 are tagged with the bare version, with the command as `xek`;
# those from the rename up to 0.10, `xek-<version>`, also as `xek`; those before it,
# `xeq-<version>`, as `xeq`. All are tried, newest naming first, and the pinned SHA-256 decides
# what is accepted, so a pin names a version and never a URL.
#
# A repository that has not yet renamed its pin is read from etc/xeq.tsv, whose hash is keyed
# `xeq`; that fallback goes once every repository has moved.
#
# Usage: etc/shared xek-fetch.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PIN=etc/xek.tsv
KEY=xek
[[ -e "$PIN" ]] || { PIN=etc/xeq.tsv; KEY=xeq; }
VERSION=$(awk -F'\t' '$1=="version"{print $2}' "$PIN")
WANT=$(awk -F'\t' -v key="$KEY" '$1==key{print $2}' "$PIN")
[[ -n "$VERSION" && -n "$WANT" ]] || { echo "xek-fetch: bad pin $PIN" >&2; exit 1; }

BASE="https://github.com/propensive/xek/releases/download"
mkdir -p dist
TMP=dist/.xek.part
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$TMP"; else wget -qO "$TMP" "$1"; fi; }
fetch "$BASE/$VERSION/xek" 2>/dev/null || fetch "$BASE/xek-$VERSION/xek" 2>/dev/null ||
  fetch "$BASE/xeq-$VERSION/xeq" ||
  { echo "xek-fetch: no builder published for version $VERSION" >&2; rm -f "$TMP"; exit 1; }
GOT=$( { sha256sum "$TMP" 2>/dev/null || shasum -a 256 "$TMP"; } | cut -d' ' -f1)
if [[ "$GOT" != "$WANT" ]]; then
  echo "xek-fetch: SHA-256 mismatch for xek (got $GOT, want $WANT)" >&2; rm -f "$TMP"; exit 1
fi
mv -f "$TMP" dist/xek
chmod +x dist/xek
echo "xek-fetch: dist/xek ($VERSION) verified"
