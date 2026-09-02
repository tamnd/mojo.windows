#!/usr/bin/env bash
# Show the overlay as a diff against the pinned upstream commit.
#
#   ./scripts/overlay-diff.sh                 everything
#   ./scripts/overlay-diff.sh bazel/config.bzl one file
#   ./scripts/overlay-diff.sh --stat           just the shape of it
#
# The overlay is stored as whole files because whole files are what you want to edit.
# This is for the other half of the job, which is reviewing what we actually changed and
# convincing yourself it is all still necessary.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git
need python3

COMMIT="$(upstream_commit)"

[ -d "$CHECKOUT/.git" ] || die "no checkout at $CHECKOUT, run scripts/sync.sh first"

cd "$CHECKOUT"
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "pinned commit $COMMIT is missing from the checkout"

# Split flags from paths, because git wants the flags before the commit and the paths
# after a --, and asking the caller to remember that would make this script pointless.
opts=()
paths=()
for arg in "$@"; do
  case "$arg" in
    -*) opts+=("$arg") ;;
    *)  paths+=("$arg") ;;
  esac
done

# Working tree rather than HEAD, so this includes edits you have not refreshed yet, which
# is the state you are usually in when you want to look.
exec git diff --no-renames ${opts[@]+"${opts[@]}"} "$COMMIT" -- ${paths[@]+"${paths[@]}"}
