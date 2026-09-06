#!/usr/bin/env bash
# Copy a sysroot made by windows-sysroot.sh onto a Windows filesystem.
#
#   ./scripts/windows-sysroot-copy.sh /mnt/c/winsysroot
#   ./scripts/windows-sysroot-copy.sh /mnt/c/winsysroot /path/to/splat
#
# Only needed if you are building on Windows rather than cross compiling to it. The cross
# lane reads the splat where xwin left it and this script has nothing to do with it.
#
# xwin is a linux-musl binary, so windows-sysroot.sh cannot run on Windows and the splat
# has to be made somewhere else and brought over. WSL is the easy way, since /mnt/c is the
# Windows disk, and this is the same rsync either way.
#
# Two things are dropped on the way across.
#
# Every symlink. xwin lays a lowercase link down beside each header whose real name has
# capitals in it, because a case sensitive filesystem needs both spellings and Microsoft's
# own headers include each other by both. There are about 1500 of them. NTFS is case
# insensitive, so the real file answers to either spelling on its own, and a symlink on
# /mnt/c needs privileges WSL does not always have. Dropping them costs nothing and
# removes the only part of the tree that could fail to copy.
#
# winrt and cppwinrt. They are more than half the bytes and no part of this project is a
# WinRT component. windows_sysroot_repository.bzl does not link them either, so leaving
# them behind here only means the copy matches what the build actually reads.
#
# The result is around 415 MB and takes a couple of minutes over the /mnt/c boundary.
# Pass it to Bazel the way windows-sysroot.sh says to, with the Windows spelling of the
# path, because it is the compiler on the Windows side that has to open these files:
#
#   --repo_env=MOJO_WINDOWS_SYSROOT=C:/winsysroot

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need rsync

DEST="${1:-}"
SOURCE="${2:-$REPO_ROOT/.windows-sysroot}"

[ -n "$DEST" ] || die "usage: $(basename "$0") <destination> [splat]"

for required in crt sdk; do
  [ -d "$SOURCE/$required" ] ||
    die "$SOURCE has no $required directory, so it is not a splat, see windows-sysroot.sh"
done

info "copying $SOURCE to $DEST"

mkdir -p "$DEST"

# Retried because a large copy onto /mnt/c can come back with "cannot allocate memory"
# partway through, which is the DrvFs boundary running out of something rather than
# anything being wrong with the files. Starting again picks up where it stopped.
for attempt in 1 2 3; do
  if rsync -a --no-links --delete \
    --exclude=/sdk/include/winrt \
    --exclude=/sdk/include/cppwinrt \
    "$SOURCE/" "$DEST/"; then
    break
  fi
  [ "$attempt" -lt 3 ] || die "rsync gave up after $attempt attempts"
  info "rsync failed, attempt $attempt, trying again"
  sleep 15
done

for required in crt/include sdk/include/um sdk/lib/um/x86_64; do
  [ -d "$DEST/$required" ] || die "$DEST/$required is missing, the copy did not finish"
done

info "done, $(du -sh "$DEST" 2>/dev/null | cut -f1) in $DEST"
