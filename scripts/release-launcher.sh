#!/usr/bin/env bash
#
# Publish an application to GitHub Releases from propensive/<name>: its library jars, then the
# self-fetching `<name>` executables built against them. Maven Central is not involved
# (Soundness #1929 switched the whole ecosystem to GitHub Releases).
#
# Usage: etc/shared release-launcher.sh <name> "<library> …" X.Y.Z
#
# for example `etc/shared release-launcher.sh flame "flame-core flame-web flame-client" 0.2.0`. The
# calling repository is expected to have a `<name>.launcher` assembly, a `release.stage` task
# staging the library modules' jars with their descriptors embedded, a `val <name>Version =
# "X.Y.Z"` pin in build.mill, an etc/refs naming only released dependencies, and an etc/xeq.tsv
# pin for the `xeq` builder.
#
# The assets have a strict order between them — the launcher's repackaged form externalizes each
# library by matching its SHA-256 digest against the release's PUBLISHED assets — so the release
# is made in two steps, exactly as it must be consumed:
#
#   1. The release is created (tagging HEAD) with the library jars alone: the exact bytes the local
#      publish put on the launcher's compile classpath, so the digests GitHub records are the
#      hashes Burdock computed at compile time.
#   2. Once GitHub reports the assets' digests, the launcher is assembled and repackaged with
#      `--github propensive/<name>` among its hints, the script VERIFIES that every library really
#      externalized to this release's URLs (aborting before upload if not), and the resulting
#      executables are added to the same release.
#
# The brief window in which the release exists without its executables is the cost of not needing
# Burdock to accept unverified, anticipated URLs; the release notes are amended at the end.
#
# A PUBLISHED release, not a draft: a draft's asset URLs live under an `untagged-…` path that
# changes when the draft is published, which would bake dead URLs into the launcher.
#
# Requires: `gh` authenticated with push access to propensive/<name>.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ $# -ne 3 || -z "$3" ]]; then
  echo "Usage: $0 <name> \"<library> …\" X.Y.Z" >&2; exit 1
fi

NAME=$1
LIBRARIES=$2
VERSION=$3
UPPER=$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_')
REPO="propensive/$NAME"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "fatal: $VERSION is not of the form X.Y.Z" >&2; exit 1
fi

# The version is the coordinate the launcher resolves (`<name>Version` in build.mill), so a
# release of anything else would disagree with itself; the pin must be edited and committed.
# (`<NAME>_RELEASE_VERSION` overrides `publishVersion` for snapshots, never for a release.)
PINNED=$(sed -n "s/.*val ${NAME}Version = \"\\(.*\\)\".*/\\1/p" build.mill)
if [[ "$PINNED" != "$VERSION" ]]; then
  echo "fatal: build.mill pins ${NAME}Version=$PINNED, not $VERSION; bump and commit first" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "fatal: the working tree is not clean" >&2; exit 1
fi

# A release may depend only on releases: every pin in etc/refs, transitively, must be a
# published X.Y.Z (a snapshot is an unreleased build that may be deleted; see deps.py).
"$PROPENSIVE_SHARED" deps.py check

# The `xeq` builder script packages the executables and the dispatcher. Fetch (and verify) it
# before anything is published, so a failed download cannot leave a half-made release behind.
"$PROPENSIVE_SHARED" xeq-fetch.sh

# Build the libraries from scratch and stage them as release assets: `release.stage` embeds
# each jar's POM and ivy.xml under META-INF/maven/, so the jar alone lets a consumer's
# `sync-deps.sh` (or the flair plugin's `-Xplugin:` resolution in Soundness) install it. The
# staged jars are then installed into ~/.ivy2/local — over whatever `publishLocal` left — so the
# launcher's compile classpath holds exactly the bytes being released, which is what Burdock
# hashes at compile time and matches against the release's assets.
./mill clean $NAME >/dev/null
./mill release.stage
STAGE_DIR="out/release/stage.dest"
"$PROPENSIVE_SHARED" sync_releases.py --staged "$STAGE_DIR"

STAGING=$(mktemp -d)
declare -A LOCAL_DIGEST
for lib in $LIBRARIES; do
  jar="$STAGE_DIR/$lib-$VERSION.jar"
  if [[ ! -f "$jar" ]]; then
    echo "fatal: $jar was not staged; is $lib in release.modules?" >&2; exit 1
  fi
  cp "$jar" "$STAGING/$lib-$VERSION.jar"
  LOCAL_DIGEST[$lib]=$(shasum -a 256 "$jar" | cut -d' ' -f1)
done

# Step 1: the release, with the libraries alone. `--target` ties the tag to the commit being
# released even if main moves while the launcher builds.
gh release create "$VERSION" --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "$NAME $VERSION" --notes "Uploading…" "$STAGING"/$NAME-*.jar

# GitHub computes each asset's SHA-256 shortly after upload; Burdock indexes by that digest, so
# wait for them all and confirm each matches the local bytes.
for lib in $LIBRARIES; do
  asset="$lib-$VERSION.jar"
  DIGEST=""
  for i in $(seq 1 60); do
    DIGEST=$(gh api "repos/$REPO/releases/tags/$VERSION" \
      --jq ".assets[] | select(.name == \"$asset\") | .digest // \"\"" 2>/dev/null || true)
    [[ -n "$DIGEST" ]] && break
    sleep 5
  done
  if [[ "$DIGEST" != "sha256:${LOCAL_DIGEST[$lib]}" ]]; then
    echo "fatal: released digest '$DIGEST' for $asset does not match local sha256:${LOCAL_DIGEST[$lib]}" >&2
    exit 1
  fi
  echo "released $asset ($DIGEST)"
done

# Step 2: the launcher, repackaged against the now-published libraries. `clean` first: the
# launcher's dependency is a fixed coordinate, and Mill's cached resolution would not notice a
# fresh publishLocal under the same version.
./mill clean $NAME.launcher >/dev/null
./mill $NAME.launcher.assembly
cp out/$NAME/launcher/assembly.dest/out.jar $NAME.jar
java -cp $NAME.jar soundness.repackage \
  --github propensive/$NAME,propensive/pyrocosm,propensive/soundness,propensive/proscala | tee /tmp/$NAME-release-repackage.log

# The whole point of the two-step dance: refuse to ship an executable that quietly inlined a
# library instead of referring to the release.
for lib in $LIBRARIES; do
  if ! grep -q "propensive/$NAME/releases/download/$VERSION/$lib-$VERSION.jar" /tmp/$NAME-release-repackage.log
  then
    echo "fatal: $lib did not externalize against this release; not uploading" >&2
    exit 1
  fi
done

# One executable per supported platform, all assembled here: an XEQ executable is a bare runner
# stub, a configuration record and the (platform-independent) repackaged JAR joined end to end,
# not compiled, so `xeq build --target` cross-"builds" every platform from this machine. The
# stubs are fetched from the pinned `xeq` release and digest-verified by the script.
PLATFORMS="linux-x64 linux-arm64 macos-x64 macos-arm64 windows-x64"
DIST=$(mktemp -d)
for platform in $PLATFORMS; do
  ext=""; [[ "$platform" == windows-* ]] && ext=".exe"
  dist/xeq build --jar $NAME.jar --out "$DIST/$NAME-$platform$ext" --target "$platform"
done
gh release upload "$VERSION" --repo "$REPO" "$DIST"/$NAME-*

# The `<name>` polyglot bootstrap: a small any-shell script (rename to <name>.bat/<name>.ps1 on
# Windows) embedding each executable's URL and checksum, which downloads the right one,
# verifies it, replaces itself and re-invokes. Built by `xeq dispatch`.
# The manifest needs the executables' digests, which GitHub computes asynchronously — poll as
# for the libraries.
MANIFEST=$(mktemp)
for i in $(seq 1 60); do
  gh api "repos/$REPO/releases/tags/$VERSION" --jq \
    ".assets[] | select((.name | startswith(\"$NAME-\")) and (.name | endswith(\".jar\") | not))
     | .name + \"\\t\" + .browser_download_url + \"\\t\" + (.digest // \"\" | sub(\"sha256:\"; \"\"))" \
    > "$MANIFEST"
  grep -qv $'\t$' "$MANIFEST" && ! grep -q $'\t$' "$MANIFEST" && break
  sleep 5
done
sed -i.bak "s/^$NAME-//; s/\\.exe\t/\t/" "$MANIFEST"

SNIPPET=""
dist/xeq dispatch --out "$DIST/$NAME" --manifest "$MANIFEST"
gh release upload "$VERSION" --repo "$REPO" "$DIST/$NAME"

# The install one-liner for the notes: a minimal bootstrap (106 bytes of POSIX shell,
# base64-armored), pointed at the polyglot script above, so the three layers compose: one-liner
# -> dispatcher script -> native executable, each download SHA-256-verified. The armored payload is constant; only the URL and hash vary per release.
SCRIPT_DIGEST=""
for i in $(seq 1 60); do
  SCRIPT_DIGEST=$(gh api "repos/$REPO/releases/tags/$VERSION" \
    --jq ".assets[] | select(.name == \"$NAME\") | .digest // \"\"" | sed 's/^sha256://')
  [[ -n "$SCRIPT_DIGEST" ]] && break
  sleep 5
done
if [[ -n "$SCRIPT_DIGEST" ]]; then
  SNIPPET=$(printf 'Install (any POSIX shell):\n\n```sh\nopenssl base64 -d <<EOF | sh -s -- https://github.com/%s/releases/download/%s/%s %s\nZj1gbWt0ZW1wYDtjdXJsIC1zTG8gJGYgJDF8fHdnZXQgLXFPICRmICQxO2Nhc2UgYG9wZW5zc2wg\nZGdzdCAtc2hhMjU2ICRmYCBpbiAqJDIpY2htb2QgK3ggJGY7ZXhlYyAkZjtlc2Fj\nEOF\n```\n\n' "$REPO" "$VERSION" "$NAME" "$SCRIPT_DIGEST")
fi

# The installer served from https://<name>.propensive.dev/ (`curl -fsSL … | sh`): plain POSIX
# shell, embedding this release's per-platform digests, generated once they are all known and
# attached to the release as `install.sh` — the domain redirects to that asset.
"$PROPENSIVE_SHARED" generate-install.sh "$NAME" "$VERSION" > "$DIST/install.sh"
gh release upload "$VERSION" --repo "$REPO" "$DIST/install.sh"

LIBRARY_LIST=$(printf '`%s`, ' $LIBRARIES); LIBRARY_LIST=${LIBRARY_LIST%, }
if [[ $LIBRARY_LIST == *,* ]]
then LIBRARY_LIST="${LIBRARY_LIST%, *} and ${LIBRARY_LIST##*, } libraries"
else LIBRARY_LIST="$LIBRARY_LIST library"
fi
gh release edit "$VERSION" --repo "$REPO" --notes \
  "${SNIPPET}The \`$NAME\` polyglot bootstrap (a small any-shell script — rename to \`$NAME.bat\` or \`$NAME.ps1\` on Windows — which downloads the right executable below, verifies its checksum, replaces itself and re-invokes), one \`$NAME\` executable per platform, and the $LIBRARY_LIST each executable externalizes, resolving further dependencies from the Soundness and proscala releases and Maven Central on first run."
echo "release $VERSION complete: $LIBRARIES + $(cd "$DIST" && echo $NAME*)"
