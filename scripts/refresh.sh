#!/usr/bin/env bash
# Regenerate patches/ from the commits sitting on top of the pinned upstream commit.
# Run this after you commit a change inside .upstream/modular.
#
#   ./scripts/refresh.sh
#
# Every commit between the pinned upstream commit and HEAD becomes one file in patches/.
# Keep commits small and give them a good subject line, because the subject line is the
# patch filename and is what an upstream reviewer reads first.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git

COMMIT="$(upstream_commit)"

[ -d "$CHECKOUT/.git" ] || die "no checkout at $CHECKOUT, run scripts/sync.sh first"

cd "$CHECKOUT"

git cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "pinned commit $COMMIT is missing from the checkout"

if [ -n "$(git status --porcelain)" ]; then
  die "you have uncommitted changes in $CHECKOUT. Commit them first, one logical change per commit."
fi

AHEAD="$(git rev-list --count "$COMMIT"..HEAD)"
if [ "$AHEAD" -eq 0 ]; then
  info "nothing on top of the pin, patches/ left alone"
  exit 0
fi

info "exporting $AHEAD commits"

rm -f "$PATCH_DIR"/*.patch
git format-patch \
  --no-signature \
  --zero-commit \
  --no-numbered \
  --keep-subject \
  -o "$PATCH_DIR" \
  "$COMMIT"..HEAD >/dev/null

# --zero-commit keeps the "From <sha>" line stable so rebases do not churn the diff.
info "wrote $(patch_count) patches to patches/"
git -C "$REPO_ROOT" status --short patches/ || true
