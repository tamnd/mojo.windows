#!/usr/bin/env bash
# Builds the Windows artifacts and lays them out as a release zip.
#
#   scripts/package-windows.sh                       # writes dist/
#   scripts/package-windows.sh --out /tmp/rel        # somewhere else
#   scripts/package-windows.sh --version 0.4.2       # name the archive
#
# What comes out is a runtime and an example, not a toolchain. There is no
# mojo.exe in here because there is no Windows build of the compiler yet: the
# compiler runs on Linux and cross compiles, so the thing a user can download
# today is the runtime a Mojo program needs and one program that uses it. The
# toolchain arrives with native hosting in M6 and drops into the same bin/.
#
# The DLLs go in bin/ next to the executable rather than in lib/ next to their
# import libraries, because Windows looks for a DLL beside the program before
# anywhere else and does not look in a sibling directory at all. The tidy split
# was tried and the example failed to start with 0xC0000135 and no message,
# which is the least helpful first impression this archive could make.
#
# Debug information goes in a second archive rather than inline. A .pdb is
# several times the size of the binary it describes, so bundling them doubles a
# download that most people will never debug, and shipping none at all makes
# every crash report useless. Two files is the usual answer and it is the one
# here.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OUT_DIR="$REPO_ROOT/dist"
VERSION=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
    --version) VERSION="${2:?--version needs a string}"; shift 2 ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

need zip
need sha256sum

[ -x "$CHECKOUT/bazelw" ] ||
  die "$CHECKOUT/bazelw does not exist, run scripts/sync.sh first"

SYSROOT="${MOJO_WINDOWS_SYSROOT:-$REPO_ROOT/.windows-sysroot}"
[ -d "$SYSROOT" ] ||
  die "no Windows sysroot at $SYSROOT, run scripts/windows-sysroot.sh first"

# Untagged builds get named after the commit rather than after nothing, so two
# archives from two different trees cannot end up with the same file name.
if [ -z "$VERSION" ]; then
  VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null ||
    echo unknown)"
  VERSION="${VERSION#v}"
fi

NAME="mojo-windows-runtime-$VERSION-x86_64"
STAGE="$OUT_DIR/$NAME"

# /DEBUG on the command line rather than in the toolchain. Asking for it in
# bazel/internal/cc-toolchain would put a .pdb next to every one of the couple
# of hundred Windows test executables, which is several gigabytes of build tree
# for debug information nobody reads. Here it applies to one build of three
# shared libraries.
# The comma in -Wl,/DEBUG is part of the flag, not a separator.
# shellcheck disable=SC2054
BAZEL_ARGS=(
  --config=build-mojo
  --config=windows-cross
  "--repo_env=MOJO_WINDOWS_SYSROOT=$SYSROOT"
  --linkopt=-Wl,/DEBUG
)

TARGET="//Mojo/examples/windows-hello:hello"

info "building $TARGET for Windows"
(cd "$CHECKOUT" && ./bazelw build "${BAZEL_ARGS[@]}" "$TARGET" >&2)

# cquery rather than a hardcoded path, because the output directory name has a
# configuration hash in it that changes whenever the Windows config does. The
# files it names are symlinks into the real output tree, and the import library
# and the .pdb sit next to the target of the link rather than next to the link,
# so everything below resolves first and then looks around.
mapfile -t FILES < <(cd "$CHECKOUT" &&
  ./bazelw cquery "${BAZEL_ARGS[@]}" --output=files "$TARGET" 2>/dev/null)
[ "${#FILES[@]}" -gt 0 ] || die "cquery named no files for $TARGET"

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/example" "$OUT_DIR/pdb-$VERSION"

PDB_STAGE="$OUT_DIR/pdb-$VERSION"
dlls=()

for rel in "${FILES[@]}"; do
  real="$(readlink -f "$CHECKOUT/$rel")"
  [ -f "$real" ] || die "$rel does not resolve to a file"
  base="$(basename "$real")"
  case "$base" in
    *.dll)
      cp "$real" "$STAGE/bin/$base"
      dlls+=("$base")
      # On Windows a shared library is two files. The .dll is what ships and
      # the import library is what a link needs, and a manifest written for a
      # Unix .so drops the second one without a word. Then the distribution
      # runs and cannot be linked against, which is a bug nobody finds until
      # somebody tries to build against it.
      stem="${base%.dll}"
      lib="$(dirname "$real")/$stem.if.lib"
      [ -f "$lib" ] || die "no import library next to $base, looked for $stem.if.lib"
      cp "$lib" "$STAGE/lib/$stem.lib"
      pdb="$(dirname "$real")/$stem.pdb"
      [ -f "$pdb" ] && cp "$pdb" "$PDB_STAGE/$stem.pdb"
      ;;
    *.exe)
      cp "$real" "$STAGE/bin/$base"
      ;;
    *) ;;
  esac
done

[ "${#dlls[@]}" -gt 0 ] || die "no shared libraries came out of the build"

cp "$REPO_ROOT/LICENSE" "$REPO_ROOT/NOTICE" "$STAGE/"
cp "$CHECKOUT/Mojo/examples/windows-hello/hello.mojo" "$STAGE/example/hello.mojo"

# The pin goes in the archive, because a bug report against a binary is close to
# useless without knowing which upstream tree it came from.
cp "$REPO_ROOT/upstream.lock" "$STAGE/upstream.lock"

cat > "$STAGE/README.txt" <<EOF
mojo.windows $VERSION, x86_64

Unofficial community build of the Mojo runtime for Windows. Not affiliated with
Modular or Qualcomm. See NOTICE.

This is a runtime and an example, not a toolchain. There is no compiler in here.
The compiler runs on Linux and cross compiles to Windows, so what you can do
with this archive is run the example and link against the runtime, and what you
cannot do is build a Mojo program on Windows. That arrives with native hosting.

  bin\\hello.exe       a Mojo program, cross compiled, run it or double click it
  bin\\*.dll           the runtime, which has to sit next to the program
  lib\\*.lib           the import libraries, needed at link time
  example\\hello.mojo  the source bin\\hello.exe was built from
  upstream.lock       the upstream commit this was built from

Keep the DLLs beside whatever uses them. Copy bin\\hello.exe somewhere on its own
and it will fail to start with 0xC0000135 and no message, which is Windows for a
missing DLL.

Requires Windows 10 version 1809 or later, x64. No Visual C++ redistributable is
needed: the C runtime is linked statically, so these import KERNEL32.dll and each
other and nothing else.

Debug information is a separate download, because the symbols are several times
the size of the binaries and most people will never need them:

  $NAME-pdb.zip

https://github.com/tamnd/mojo.windows
EOF

info "packing"
archives=("$NAME.zip")
(cd "$OUT_DIR" && zip -qr "$NAME.zip" "$NAME")

if [ -n "$(ls -A "$PDB_STAGE")" ]; then
  (cd "$PDB_STAGE" && zip -qr "../$NAME-pdb.zip" .)
  archives+=("$NAME-pdb.zip")
fi
rm -rf "$STAGE" "$PDB_STAGE"

# SHA256SUMS-windows and not SHA256SUMS, because the release workflow already
# publishes a SHA256SUMS for the overlay archives it builds itself and these two
# sets are produced in different places by different people. One file per set is
# clearer than one file somebody has to remember to merge by hand.
(cd "$OUT_DIR" && sha256sum "${archives[@]}" > SHA256SUMS-windows)

info "wrote $OUT_DIR/$NAME.zip"
cat "$OUT_DIR/SHA256SUMS-windows" >&2
