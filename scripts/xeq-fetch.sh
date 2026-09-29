#!/usr/bin/env bash
#
# Fetch the pinned `xeq` builder script into dist/xeq, verified against etc/xeq.tsv.
#
# `xeq` is the single implementation of the XEQ executable format, published from
# propensive/xek (formerly propensive/xeq) with the runner stubs. Applications shell out to it to
# package their executables rather than carrying a copy of their own; each repository pins the
# version and the script's SHA-256 in its own etc/xeq.tsv, so this script can be shared while the
# pin stays local. Releases since the rename are tagged `xek-<version>` with the script as `xek`;
# those before it, `xeq-<version>` with the script as `xeq`. Both are tried, newest naming first,
# and the pinned SHA-256 decides what is accepted, so a pin names a version and never a URL.
#
# Usage: etc/shared xeq-fetch.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PIN=etc/xeq.tsv
VERSION=$(awk -F'\t' '$1=="version"{print $2}' "$PIN")
WANT=$(awk -F'\t' '$1=="xeq"{print $2}' "$PIN")
[[ -n "$VERSION" && -n "$WANT" ]] || { echo "xeq-fetch: bad pin $PIN" >&2; exit 1; }

BASE="https://github.com/propensive/xek/releases/download"
mkdir -p dist
TMP=dist/.xeq.part
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$TMP"; else wget -qO "$TMP" "$1"; fi; }
fetch "$BASE/xek-$VERSION/xek" 2>/dev/null || fetch "$BASE/xeq-$VERSION/xeq" ||
  { echo "xeq-fetch: no builder script published for version $VERSION" >&2; rm -f "$TMP"; exit 1; }
GOT=$( { sha256sum "$TMP" 2>/dev/null || shasum -a 256 "$TMP"; } | cut -d' ' -f1)
if [[ "$GOT" != "$WANT" ]]; then
  echo "xeq-fetch: SHA-256 mismatch for xeq (got $GOT, want $WANT)" >&2; rm -f "$TMP"; exit 1
fi
mv -f "$TMP" dist/xeq
chmod +x dist/xeq
echo "xeq-fetch: dist/xeq ($VERSION) verified"
