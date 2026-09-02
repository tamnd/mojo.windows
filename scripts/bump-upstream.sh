#!/usr/bin/env bash
# Move the pin to a newer upstream commit and check the patch series still applies.
#
#   ./scripts/bump-upstream.sh                  # newest mojo/* tag
#   ./scripts/bump-upstream.sh mojo/v1.0.1      # a specific tag
#   ./scripts/bump-upstream.sh --branch main    # tip of a branch, for nightly chasing
#
# On success it rewrites upstream.lock and patches/ and leaves the result staged for you
# to review. On failure it leaves upstream.lock untouched and prints which patches broke.
# The weekly workflow in .github/workflows/upstream-sync.yml runs this and opens a PR.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git
need python3

REPO="$(upstream_repo)"
OLD_COMMIT="$(upstream_commit)"
OLD_TAG="$(upstream_tag)"

MODE=tag
TARGET="${1:-}"
if [ "$TARGET" = "--branch" ]; then
  MODE=branch
  TARGET="${2:-main}"
fi

mkdir -p "$WORK_DIR"
if [ ! -d "$CHECKOUT/.git" ]; then
  info "cloning upstream"
  git clone --filter=blob:none --no-checkout "$REPO" "$CHECKOUT"
fi

cd "$CHECKOUT"
info "fetching upstream refs"
git fetch --filter=blob:none --tags --force origin

if [ "$MODE" = branch ]; then
  NEW_REF="refs/heads/$TARGET"
  NEW_TAG="$TARGET"
  NEW_COMMIT="$(git rev-parse "origin/$TARGET")"
else
  if [ -z "$TARGET" ]; then
    # Newest mojo/vX.Y.Z tag by commit date, ignoring prereleases.
    TARGET="$(git tag --list 'mojo/v*' --sort=-creatordate | grep -Ev 'b[0-9]+$' | head -n1)"
    [ -n "$TARGET" ] || die "could not work out the newest mojo/* tag"
  fi
  git rev-parse -q --verify "refs/tags/$TARGET" >/dev/null || die "no such tag upstream: $TARGET"
  NEW_REF="refs/tags/$TARGET"
  NEW_TAG="$TARGET"
  NEW_COMMIT="$(git rev-parse "refs/tags/$TARGET^{commit}")"
fi

if [ "$NEW_COMMIT" = "$OLD_COMMIT" ]; then
  info "already pinned to $NEW_TAG ($NEW_COMMIT), nothing to do"
  exit 0
fi

info "old pin $OLD_TAG ($OLD_COMMIT)"
info "new pin $NEW_TAG ($NEW_COMMIT)"
info "upstream moved $(git rev-list --count "$OLD_COMMIT".."$NEW_COMMIT" 2>/dev/null || echo '?') commits"

BRANCH="windows/$(printf '%s' "$NEW_TAG" | tr '/' '-')"
git checkout -q --detach "$NEW_COMMIT"
git branch -q -f "$BRANCH" "$NEW_COMMIT"
git checkout -q "$BRANCH"

COUNT="$(patch_count)"
if [ "$COUNT" -gt 0 ]; then
  info "replaying $COUNT patches onto $NEW_TAG"
  if ! git am --3way --keep-non-patch "$PATCH_DIR"/*.patch; then
    FAILED="$(git am --show-current-patch=raw 2>/dev/null | sed -n 's/^Subject: //p' | head -n1)"
    git am --abort || true
    cat >&2 <<MSG

The bump to $NEW_TAG failed. upstream.lock has not been changed.

First patch that did not apply: ${FAILED:-unknown}

To work it out by hand:

    git -C .upstream/modular checkout $BRANCH
    git -C .upstream/modular am --3way --keep-non-patch patches/*.patch
    # fix the conflict, then
    git -C .upstream/modular am --continue
    ./scripts/refresh.sh
    # then rerun this script

MSG
    exit 1
  fi
fi

info "series applied cleanly, updating the lock"
python3 - "$LOCK_FILE" "$NEW_REF" "$NEW_TAG" "$NEW_COMMIT" <<'PY'
import json, sys, datetime, collections
path, ref, tag, commit = sys.argv[1:5]
with open(path) as f:
    data = json.load(f, object_pairs_hook=collections.OrderedDict)
data["ref"] = ref
data["tag"] = tag
data["commit"] = commit
data["pinned_at"] = datetime.date.today().isoformat()
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

"$REPO_ROOT/scripts/refresh.sh"

info "bumped $OLD_TAG -> $NEW_TAG"
info "review the diff to upstream.lock and patches/, then commit"
