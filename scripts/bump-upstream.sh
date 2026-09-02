#!/usr/bin/env bash
# Move the pin to a newer upstream commit and merge our overlay onto it.
#
#   ./scripts/bump-upstream.sh                  # tip of main, see the note below
#   ./scripts/bump-upstream.sh mojo/v1.1.0      # a specific tag
#   ./scripts/bump-upstream.sh --branch main    # tip of a branch
#   ./scripts/bump-upstream.sh --commit <sha>   # an exact commit
#
# The default is the tip of main rather than the newest release tag, which is not what
# you would normally want. The reason is that the newest mojo/v* release tag is v1.0.0
# from 11 August 2026, and the compiler was not open sourced until after it. That tag
# contains the standard library and nothing else, so every file this project needs to
# change is absent from it. Until there is a release tag carrying the compiler, tracking
# main is the only option. Switch the default back the moment one exists.
#
# For every file the overlay owns, this does a real three way merge: upstream's version at
# the old pin as the base, ours as one side, upstream's version at the new pin as the
# other. Files upstream did not touch pass straight through. Files it did touch get merged,
# and anything git cannot resolve is left in overlay/ with conflict markers for a human.
#
# On success it rewrites upstream.lock and overlay/ and leaves the result for you to
# review. On failure it leaves upstream.lock untouched and says which files need hands.
# The weekly workflow in .github/workflows/upstream-sync.yml runs this and opens a PR.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git
need python3

REPO="$(upstream_repo)"
OLD_COMMIT="$(upstream_commit)"
OLD_TAG="$(upstream_tag)"

MODE=branch
TARGET="${1:-}"
case "$TARGET" in
  --branch) MODE=branch; TARGET="${2:-main}" ;;
  --commit) MODE=commit; TARGET="${2:-}"; [ -n "$TARGET" ] || die "--commit needs a sha" ;;
  "")       MODE=branch; TARGET=main ;;
  *)        MODE=tag ;;
esac

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
elif [ "$MODE" = commit ]; then
  NEW_COMMIT="$(git rev-parse -q --verify "$TARGET^{commit}")" || die "no such commit upstream: $TARGET"
  NEW_REF="$NEW_COMMIT"
  NEW_TAG="$(git describe --tags --always "$NEW_COMMIT" 2>/dev/null || printf '%s' "${NEW_COMMIT:0:12}")"
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

# Before anything else, check the candidate is a tree we can actually work against. This
# runs ahead of the already-pinned check on purpose, so that a plain run also tells you
# when the pin you are sitting on is the broken one.
assert_pinnable "$NEW_COMMIT"

if [ "$NEW_COMMIT" = "$OLD_COMMIT" ]; then
  info "already pinned to $NEW_TAG ($NEW_COMMIT), nothing to do"
  exit 0
fi

info "old pin $OLD_TAG ($OLD_COMMIT)"
info "new pin $NEW_TAG ($NEW_COMMIT)"
info "upstream moved $(git rev-list --count "$OLD_COMMIT".."$NEW_COMMIT" 2>/dev/null || echo '?') commits"

COUNT="$(overlay_count)"
merged=0
untouched=0
conflicts=()
gone=()
collisions=()

if [ "$COUNT" -gt 0 ]; then
  info "merging $COUNT overlay files onto $NEW_TAG"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  while IFS=$'\t' read -r state base_blob path; do
    [ -n "$path" ] || continue

    if [ "$state" = new ]; then
      if git cat-file -e "$NEW_COMMIT:$path" 2>/dev/null; then
        collisions+=("$path")
      fi
      continue
    fi

    new_blob="$(git rev-parse --verify --quiet "$NEW_COMMIT:$path" || true)"
    if [ -z "$new_blob" ]; then
      gone+=("$path")
      continue
    fi

    if [ "$new_blob" = "$base_blob" ]; then
      untouched=$((untouched + 1))
      continue
    fi

    # Upstream moved this file. For a delete there is nothing to merge, we just keep
    # deleting it, but it is worth saying so because upstream changing a file we deleted
    # is often a sign the reason we deleted it has gone away.
    if [ "$state" = delete ]; then
      merged=$((merged + 1))
      info "upstream changed $path, which we delete. Worth rechecking why we delete it."
      continue
    fi

    mkdir -p "$tmp/$(dirname "$path")"
    git cat-file blob "$base_blob" > "$tmp/$path.base"
    git cat-file blob "$new_blob" > "$tmp/$path.theirs"
    if git merge-file \
      -L "ours (mojo.windows)" -L "upstream at $OLD_TAG" -L "upstream at $NEW_TAG" \
      "$OVERLAY_DIR/$path" "$tmp/$path.base" "$tmp/$path.theirs"; then
      merged=$((merged + 1))
    else
      conflicts+=("$path")
    fi
  done < <(manifest_rows)
fi

if [ "${#conflicts[@]}" -gt 0 ] || [ "${#gone[@]}" -gt 0 ] || [ "${#collisions[@]}" -gt 0 ]; then
  printf '\n' >&2
  printf 'The bump to %s needs hands. upstream.lock has not been changed.\n\n' "$NEW_TAG" >&2
  if [ "${#conflicts[@]}" -gt 0 ]; then
    printf 'Conflicting, and now sitting in overlay/ with markers in them:\n' >&2
    printf '  %s\n' "${conflicts[@]}" >&2
    printf '\n' >&2
  fi
  if [ "${#gone[@]}" -gt 0 ]; then
    printf 'Deleted upstream, so our version of them has nothing to sit on:\n' >&2
    printf '  %s\n' "${gone[@]}" >&2
    printf '\n' >&2
  fi
  if [ "${#collisions[@]}" -gt 0 ]; then
    printf 'We add these and upstream now has its own file at the same path:\n' >&2
    printf '  %s\n' "${collisions[@]}" >&2
    printf '\n' >&2
  fi
  cat >&2 <<MSG
Resolve them in overlay/, then rerun this script. The conflict markers name the
three sides: ours, upstream at $OLD_TAG, upstream at $NEW_TAG.

To throw the half merged overlay away and start again:

    git checkout -- overlay/

MSG
  exit 1
fi

info "merged cleanly, $merged files merged, $untouched untouched"
info "updating the lock"
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

# The recorded blobs still name the old pin, so sync.sh would report drift on every file
# upstream touched. Laying the merged overlay down on the new pin and refreshing rewrites
# them, and has the side effect of proving the merged overlay actually applies. The reset
# is so sync.sh does not refuse on a tree that still holds the old pin's overlay commit,
# and it is a reset rather than a delete because re-cloning upstream costs minutes.
git -C "$CHECKOUT" checkout -q --force --detach "$NEW_COMMIT"
git -C "$CHECKOUT" clean -qfd
"$REPO_ROOT/scripts/sync.sh"
"$REPO_ROOT/scripts/refresh.sh"

info "bumped $OLD_TAG -> $NEW_TAG"
info "review the diff to upstream.lock and overlay/, then commit"
