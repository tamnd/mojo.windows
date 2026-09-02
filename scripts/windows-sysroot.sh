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
#
# --http-retry defaults to 0, which is a strange default for something that pulls a few
# hundred files and around 630 MB off a CDN. One dropped connection and the whole run
# ends. Five is enough that a normal bad minute does not cost you the download, and the
# timeout goes up for the same reason, because 60 seconds for a single file is tight on
# a slow link.
"$WORK/xwin" \
  --accept-license \
  --arch x86_64 \
  --variant desktop \
  --http-retry 5 \
  --timeout 180s \
  splat \
  --output "$OUTPUT"

if [ ! -d "$OUTPUT/crt" ] || [ ! -d "$OUTPUT/sdk" ]; then
  die "xwin finished but $OUTPUT does not look like a splat output"
fi

info "done"
printf '\n'
# A flag and not an export, because upstream sets --experimental_strict_repo_env, which
# means a repository rule sees nothing from your shell except what --repo_env hands it.
# Exporting the variable and expecting Bazel to find it gets you an empty sysroot and a
# pile of missing header errors that look nothing like the actual problem.
printf 'Pass this to Bazel:\n'
printf '  --repo_env=MOJO_WINDOWS_SYSROOT=%s\n' "$OUTPUT"
