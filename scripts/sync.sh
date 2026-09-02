#!/usr/bin/env bash
# Fetch upstream at the pinned commit and lay our files over the top.
# This is the one command you run to get a working tree you can build.
#
#   ./scripts/sync.sh
#
# Result lands in .upstream/modular on branch windows/<pinned-tag>, with the overlay
# applied as a single commit on top of the pin. The .upstream directory is gitignored
# and is safe to delete at any time.
#
# After this, edit files in .upstream/modular like normal source, because that is what
# they are. When you are happy, run scripts/refresh.sh to copy your edits back into
# overlay/ so they end up in a commit here.

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

# Refuse to blow away work in progress. Anything on top of the overlay commit is either
# an edit that has not been refreshed yet or an experiment somebody wants to keep.
if [ -f "$READY" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  die "$CHECKOUT has uncommitted changes. Run scripts/refresh.sh to keep them, or delete the directory."
fi

info "checking out $COMMIT onto branch $BRANCH"
git checkout -q --force --detach "$COMMIT"
git branch -q -f "$BRANCH" "$COMMIT"
git checkout -q "$BRANCH"
touch "$READY"

COUNT="$(overlay_count)"
if [ "$COUNT" -eq 0 ]; then
  info "overlay is empty, tree is plain upstream at $TAG"
  exit 0
fi

info "applying $COUNT overlay files"

drift=0
drifted=()
while IFS=$'\t' read -r state want path; do
  [ -n "$path" ] || continue
  case "$state" in
    edit|delete)
      have="$(git rev-parse --verify --quiet "$COMMIT:$path" || true)"
      if [ -z "$have" ]; then
        drifted+=("$path is gone from upstream, we still have an overlay for it")
        drift=1
      elif [ "$have" != "$want" ]; then
        drifted+=("$path changed upstream since we took it over")
        drift=1
      fi
      ;;
    new)
      if git cat-file -e "$COMMIT:$path" 2>/dev/null; then
        drifted+=("$path is marked new but upstream has a file there now")
        drift=1
      fi
      ;;
    *)
      die "unknown state '$state' for $path in $MANIFEST"
      ;;
  esac

  case "$state" in
    edit|new)
      [ -f "$OVERLAY_DIR/$path" ] || die "$MANIFEST lists $path but overlay/$path does not exist"
      mkdir -p "$(dirname "$path")"
      cp "$OVERLAY_DIR/$path" "$path"
      ;;
    delete)
      rm -f "$path"
      ;;
  esac
done < <(manifest_rows)

# Committing the overlay is what makes the rest of the workflow pleasant. The tree is
# clean afterwards, so git status inside the checkout shows exactly your own edits and
# nothing else, and git diff against the pin shows the whole of what this project changes.
git add -A
git -c user.name="mojo.windows sync" \
    -c user.email="sync@localhost" \
    commit -q -m "windows overlay at $TAG

$COUNT files, applied by scripts/sync.sh. Not a change anybody wrote as a commit.
The reviewable form of this lives in overlay/ in the mojo.windows repository."

if [ "$drift" -ne 0 ]; then
  printf '\n' >&2
  printf 'warning: the pin has moved under %d overlay files:\n' "${#drifted[@]}" >&2
  printf '  %s\n' "${drifted[@]}" >&2
  cat >&2 <<'MSG'

The overlay was applied anyway, so upstream's version of those files has been
thrown away rather than merged. That is almost never what you want.

    ./scripts/overlay-diff.sh <path>    what we changed, against the blob we took it from
    git -C .upstream/modular diff <old-blob> HEAD:<path>

Reconcile by hand, then run scripts/refresh.sh, which rewrites the recorded blobs
to the current pin and makes this warning go away.
MSG
fi

info "done, $COUNT overlay files on top of $TAG"
info "working tree is $CHECKOUT on branch $BRANCH"
