#!/usr/bin/env bash
# Fetch upstream at the pinned commit and apply our patch series on top.
# This is the one command you run to get a working tree you can build.
#
#   ./scripts/sync.sh
#
# Result lands in .upstream/modular on branch windows/<pinned-tag>.
# The .upstream directory is gitignored and is safe to delete at any time.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git
need python3

REPO="$(upstream_repo)"
COMMIT="$(upstream_commit)"
TAG="$(upstream_tag)"
BRANCH="$(work_branch)"

info "upstream $REPO"
info "pinned   $TAG ($COMMIT)"

mkdir -p "$WORK_DIR"

# Written only once the working tree has actually been populated. A clone that was
# interrupted, or one made with --no-checkout, has an index full of files that have no
# working tree copy, which is indistinguishable from a tree full of deletions. Without
# this marker such a directory would trip the dirty check below on every future run and
# stay stuck forever.
READY="$WORK_DIR/.checkout-ready"

if [ ! -d "$CHECKOUT/.git" ]; then
  info "cloning upstream, this pulls a large tree and takes a while on first run"
  rm -f "$READY"
  git clone --filter=blob:none --no-checkout "$REPO" "$CHECKOUT"
fi

cd "$CHECKOUT"

# Make sure the pinned object is actually present before we try to use it.
if ! git cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
  info "fetching pinned commit"
  git fetch --filter=blob:none origin "$COMMIT" || git fetch --filter=blob:none origin
fi
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "pinned commit $COMMIT is not reachable in $REPO"

# Refuse to blow away work in progress.
if [ -f "$READY" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  die "$CHECKOUT has uncommitted changes. Commit them and run scripts/refresh.sh, or delete the directory."
fi

info "checking out $COMMIT onto branch $BRANCH"
git checkout -q --force --detach "$COMMIT"
git branch -q -f "$BRANCH" "$COMMIT"
git checkout -q "$BRANCH"
touch "$READY"

COUNT="$(patch_count)"
if [ "$COUNT" -eq 0 ]; then
  info "no patches yet, tree is plain upstream at $TAG"
  exit 0
fi

info "applying $COUNT patches"
# The committer identity is forced rather than read from the machine's git config.
# Every patch carries its own author, so whoever replays the series is not information
# anybody wants, and on a machine with no global user.name set git am refuses to run at
# all rather than picking something. That failure is confusing here, because it looks
# like the series did not apply when in fact it was never tried.
if ! git -c user.name="mojo.windows sync" \
        -c user.email="sync@localhost" \
        am --3way --keep-non-patch "$PATCH_DIR"/*.patch; then
  cat >&2 <<'MSG'

The patch series did not apply cleanly.

Fix the conflict in the working tree, then:

    git -C .upstream/modular am --continue
    ./scripts/refresh.sh

Or abandon this attempt with:

    git -C .upstream/modular am --abort

MSG
  exit 1
fi

info "done, $COUNT patches applied on top of $TAG"
info "working tree is $CHECKOUT on branch $BRANCH"
