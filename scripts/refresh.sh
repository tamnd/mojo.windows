#!/usr/bin/env bash
# Copy your edits out of the upstream checkout and into overlay/, where they get committed.
# Run this after you change anything inside .upstream/modular.
#
#   ./scripts/refresh.sh
#
# You do not have to tell it which files you touched. It compares the checkout against the
# pinned upstream commit and takes everything that differs, which means adopting a file you
# have never edited before is just editing it.
#
# The result is real files under overlay/ at their upstream paths, so a pull request here
# shows a normal diff of source code rather than a diff of a diff.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git
need python3

COMMIT="$(upstream_commit)"

[ -d "$CHECKOUT/.git" ] || die "no checkout at $CHECKOUT, run scripts/sync.sh first"

cd "$CHECKOUT"

git cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "pinned commit $COMMIT is missing from the checkout"

# Everything that differs from the pin, whether committed, staged, unstaged or untracked.
# --no-renames because a rename is a delete plus a new file as far as the overlay is
# concerned, and letting git call it a rename would hide one half of it.
mapfile -t changed < <(
  {
    git diff --name-only --no-renames "$COMMIT"
    git ls-files --others --exclude-standard
  } | sort -u
)

if [ "${#changed[@]}" -eq 0 ]; then
  info "checkout matches the pin exactly, overlay left alone"
  exit 0
fi

info "found ${#changed[@]} files that differ from the pin"

rm -rf "$OVERLAY_DIR"
mkdir -p "$OVERLAY_DIR"

rows=()
for path in "${changed[@]}"; do
  upstream_blob="$(git rev-parse --verify --quiet "$COMMIT:$path" || true)"
  if [ -e "$path" ]; then
    if [ -n "$upstream_blob" ]; then
      state=edit
      blob="$upstream_blob"
    else
      state=new
      blob="-"
    fi
    mkdir -p "$OVERLAY_DIR/$(dirname "$path")"
    cp "$path" "$OVERLAY_DIR/$path"
    # Executable bit is the only mode git tracks and it is the one that matters here,
    # because a build script that arrives without it fails in a way nobody enjoys reading.
    [ -x "$path" ] && chmod +x "$OVERLAY_DIR/$path"
  else
    [ -n "$upstream_blob" ] || die "$path is neither in the checkout nor at the pin, which should be impossible"
    state=delete
    blob="$upstream_blob"
  fi
  rows+=("$state	$blob	$path")
done

{
  printf '# Files this project takes ownership of, relative to the upstream tree root.\n'
  printf '# Written by scripts/refresh.sh. Edit the files under overlay/, not this list.\n'
  printf '#\n'
  printf '#   state  upstream blob at the pin  path\n'
  printf '#\n'
  printf '# state is edit, new or delete. The blob is what upstream had when we took the\n'
  printf '# file over, and sync.sh compares against it so that a moved pin reports which of\n'
  printf '# our files upstream has changed underneath us instead of silently reverting them.\n'
  printf '#\n'
  printf '# pin %s\n' "$(upstream_tag)"
  printf '\n'
  printf '%s\n' "${rows[@]}" | LC_ALL=C sort -k3,3
} > "$MANIFEST"

info "wrote $(overlay_count) files to overlay/"
git -C "$REPO_ROOT" status --short overlay/ || true
