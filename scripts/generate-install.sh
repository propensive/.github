#!/bin/sh
#
# Generates the install script for a release of an application published from propensive/<name>,
# served from https://propensive.dev/<name>, embedding the release's per-platform digests of the
# executables `<name>-<platform>`. Run by release.sh once every executable's digest is known, and
# by a repository's own `assemble` step (xek's) before its release exists.
#
# Usage: etc/shared generate-install.sh <name> X.Y.Z [tag [assets]] > install.sh
#
# The tag defaults to the version, and names the release the executables are downloaded from.
# The digests are GitHub's, for the published release, unless `assets` names a directory holding
# the executables themselves, when they are computed from its files: which is safe, because
# release.sh checks every asset it uploads against the digest GitHub then records.

set -e

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
  echo "Usage: $0 <name> X.Y.Z [tag [assets]]" >&2; exit 1
fi

NAME=$1
VERSION=$2
TAG=${3:-$VERSION}
ASSETS=${4:-}
UPPER=$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_')
BASE="https://github.com/propensive/$NAME/releases/download/$TAG"

H() {
  if [ -n "$ASSETS" ]; then
    { sha256sum "$ASSETS/$1" 2>/dev/null || shasum -a 256 "$ASSETS/$1"; } | cut -d' ' -f1
  else
    gh api "repos/propensive/$NAME/releases/tags/$TAG" --jq ".assets[] | select(.name==\"$1\") | .digest" | sed 's/sha256://'
  fi
}

# Every digest is read before the script is written: a command substitution inside the here-document
# below could fail without stopping this script, and an installer embedding an empty digest would
# refuse every download it makes.
for label in linux-x64 linux-arm64 macos-x64 macos-arm64; do
  digest=$(H "$NAME-$label")
  case "$digest" in
    *[!0-9a-f]*|'') echo "generate-install: no SHA-256 for $NAME-$label" >&2; exit 1 ;;
  esac
  eval "DIGEST_$(printf '%s' "$label" | tr - _)=\$digest"
done

# A line of the closing box, padded to its width whatever the name's length.
BOX() { printf '# ┃  %-82s┃\n' "$1"; }
cat <<EOF
#!/bin/sh

# The $NAME installer, served from https://propensive.dev/$NAME for:
#
#     curl -fsSL https://propensive.dev/$NAME | sh
#
# Detects the operating system and CPU architecture, downloads the matching \`$NAME\`
# executable from the GitHub release, verifies its SHA-256 against the digest embedded
# below, and installs it as \`$NAME\` in ~/.local/bin (or \$${UPPER}_INSTALL_DIR). POSIX shell
# only; no stdin is read, so piping from curl is safe.
#
# Generated for $NAME $VERSION by release.sh; the digests are per-release.

set -e

version="$VERSION"
base="$BASE"

case "\$(uname -s)" in
  Darwin) os=macos ;;
  Linux)  os=linux ;;
  *)      echo "$NAME: unsupported operating system: \$(uname -s)" >&2
          echo "$NAME: (on Windows, download \$base/$NAME-windows-x64.exe)" >&2
          exit 1 ;;
esac

case "\$(uname -m)" in
  x86_64|amd64)  arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *)             echo "$NAME: unsupported architecture: \$(uname -m)" >&2; exit 1 ;;
esac

label="\$os-\$arch"

case "\$label" in
  linux-x64)   expected=$DIGEST_linux_x64 ;;
  linux-arm64) expected=$DIGEST_linux_arm64 ;;
  macos-x64)   expected=$DIGEST_macos_x64 ;;
  macos-arm64) expected=$DIGEST_macos_arm64 ;;
  *)           echo "$NAME: no executable is published for \$label" >&2; exit 1 ;;
esac

url="\$base/$NAME-\$label"
dir="\${${UPPER}_INSTALL_DIR:-\$HOME/.local/bin}"
mkdir -p "\$dir"
tmp="\$dir/.$NAME.download.\$\$"
trap 'rm -f "\$tmp"' EXIT

echo "Downloading $NAME \$version for \$label..."
if command -v curl >/dev/null 2>&1
then curl -fsSL "\$url" -o "\$tmp"
elif command -v wget >/dev/null 2>&1
then wget -qO "\$tmp" "\$url"
else echo "$NAME: neither curl nor wget is available" >&2; exit 1
fi

if command -v sha256sum >/dev/null 2>&1
then actual=\$(sha256sum "\$tmp" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1
then actual=\$(shasum -a 256 "\$tmp" | cut -d' ' -f1)
else actual=\$(openssl dgst -sha256 "\$tmp" | sed 's/.* //')
fi

if [ "\$actual" != "\$expected" ]
then
  echo "$NAME: checksum mismatch for \$url" >&2
  echo "$NAME:   expected \$expected" >&2
  echo "$NAME:   received \$actual" >&2
  exit 1
fi

chmod +x "\$tmp"
mv "\$tmp" "\$dir/$NAME"
trap - EXIT

echo "Installed $NAME \$version to \$dir/$NAME"

case ":\$PATH:" in
  *:"\$dir":*) ;;
  *) echo "Note: \$dir is not on your PATH; add it with:"
     echo "    export PATH=\"\$dir:\\\$PATH\"" ;;
esac

echo "The first run fetches $NAME's dependencies; subsequent runs start instantly."

# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃                                                                                    ┃
# ┃  If this script has been PRINTED to your terminal, it has not been run: you are    ┃
# ┃  looking at the installer itself. To download and run it in one step, invoke:      ┃
# ┃                                                                                    ┃
$(BOX "    curl -fsSL https://propensive.dev/$NAME | sh")
# ┃                                                                                    ┃
# ┃  or, if you have already saved it to a file:                                       ┃
# ┃                                                                                    ┃
# ┃      sh install.sh                                                                 ┃
# ┃                                                                                    ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
EOF
