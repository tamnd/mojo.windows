#!/usr/bin/env bash
# Build a Windows sysroot for cross compiling, using xwin.
#
#   ./scripts/windows-sysroot.sh                  # into .windows-sysroot
#   ./scripts/windows-sysroot.sh /path/to/output  # somewhere else
#
# This downloads the MSVC CRT and the Windows SDK from Microsoft's own CDN and lays them
# out for clang. It prints the path to export as MOJO_WINDOWS_SYSROOT when it finishes.
#
# It is a separate script and not something a build runs for you, on purpose. Running it
# accepts the Visual Studio licence on this machine, and a thing with legal weight should
# be something you typed rather than something that happened while you were waiting for a
# build. docs/building.md has the longer version of that argument.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need curl
need tar
need sha256sum

XWIN_VERSION="0.10.0"
XWIN_SHA256="d870eb4b2f390878af6da1ccd3cf321d22fcb72720984853b4be732ae597fc88"
XWIN_ASSET="xwin-${XWIN_VERSION}-x86_64-unknown-linux-musl.tar.gz"
XWIN_URL="https://github.com/Jake-Shadle/xwin/releases/download/${XWIN_VERSION}/${XWIN_ASSET}"

OUTPUT="${1:-$REPO_ROOT/.windows-sysroot}"
WORK="$REPO_ROOT/.xwin"

[ "$(uname -s)" = "Linux" ] || die "this script wants Linux, the pinned xwin build is a linux-musl binary"
[ "$(uname -m)" = "x86_64" ] || die "the pinned xwin build is x86_64, see the release page for other hosts"

mkdir -p "$WORK"
cd "$WORK"

if [ ! -x "$WORK/xwin" ]; then
  info "fetching xwin $XWIN_VERSION"
  curl -fsSL -o "$XWIN_ASSET" "$XWIN_URL"
  # Pinned by hash rather than trusting the tag, because a tag can be moved and this
  # binary is about to be given permission to run and to accept a licence on your behalf.
  echo "$XWIN_SHA256  $XWIN_ASSET" | sha256sum -c - >/dev/null || die "xwin checksum did not match, refusing to run it"
  tar xzf "$XWIN_ASSET"
  cp "xwin-${XWIN_VERSION}-x86_64-unknown-linux-musl/xwin" "$WORK/xwin"
fi

info "splatting into $OUTPUT"
info "this accepts the Visual Studio licence on this machine, see docs/building.md"

# Defaults are already x86_64 and desktop, which is what we want, but they are spelled out
# because the defaults are xwin's rather than ours and a later version could change them.
# They go before the subcommand and not after it, which xwin will tell you about only if
# you get it wrong.
"$WORK/xwin" \
  --accept-license \
  --arch x86_64 \
  --variant desktop \
  splat \
  --output "$OUTPUT"

[ -d "$OUTPUT/crt" ] && [ -d "$OUTPUT/sdk" ] || die "xwin finished but $OUTPUT does not look like a splat output"

info "done"
printf '\n'
printf 'export MOJO_WINDOWS_SYSROOT=%s\n' "$OUTPUT"
