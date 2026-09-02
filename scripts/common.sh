#!/usr/bin/env bash
# Shared helpers. Source this, do not run it.
#
# These are consumed by the scripts that source this file, not by this file itself.
# shellcheck disable=SC2034

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$REPO_ROOT/upstream.lock"
OVERLAY_DIR="$REPO_ROOT/overlay"
MANIFEST="$OVERLAY_DIR/MANIFEST"
WORK_DIR="${MOJO_WIN_WORKDIR:-$REPO_ROOT/.upstream}"
CHECKOUT="$WORK_DIR/modular"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found on PATH"; }

lock_get() {
  # Reads one top level string field out of upstream.lock without needing jq.
  python3 - "$LOCK_FILE" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f)[sys.argv[2]])
PY
}

upstream_repo() { lock_get repo; }
upstream_commit() { lock_get commit; }
upstream_tag() { lock_get tag; }

# Branch we build on top of. Named after the pinned tag so two pins can coexist.
work_branch() { printf 'windows/%s\n' "$(upstream_tag | tr '/' '-')"; }

# The overlay manifest. One line per file we take ownership of, three fields:
#
#   <state>  <upstream blob>  <path relative to the upstream tree root>
#
# state is edit, new or delete. The blob is what upstream had at the pin, and is a dash
# for new files. Blank lines and everything after a # are ignored.
#
# The blob is the whole point of the file. Without it a rebase to a newer pin silently
# reverts whatever upstream did to a file we also changed, and nothing tells you. With it,
# sync.sh compares and says which of our files upstream has moved under us.

manifest_rows() {
  [ -f "$MANIFEST" ] || return 0
  # shellcheck disable=SC2016
  python3 - "$MANIFEST" <<'PY'
import sys
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    parts = line.split()
    if len(parts) != 3:
        sys.exit("error: bad manifest line: %s" % raw.rstrip())
    print("\t".join(parts))
PY
}

overlay_paths() { manifest_rows | cut -f3; }
overlay_count() { overlay_paths | grep -c . || true; }

# Paths that have to exist in any commit we are willing to pin to. The compiler was open
# sourced after the mojo/v1.0.0 tag, so there are real upstream refs whose tree holds the
# standard library and nothing else. Pinning to one of those looks fine right up until
# every patch fails to apply against files that are not there, which is a confusing way
# to spend an afternoon. Checked at bump time so it can never happen twice.
REQUIRED_UPSTREAM_PATHS=(
  "Support/BUILD.bazel"
  "Mojo/lib/KGENToLLVM/CABILowering.cpp"
  "Mojo/tools/mojo/Build/mojo-build.cpp"
  "Mojo/stdlib"
)

assert_pinnable() {
  # Usage: assert_pinnable <commit>. Must be run inside the upstream checkout.
  local commit="$1" missing=()
  local p
  for p in "${REQUIRED_UPSTREAM_PATHS[@]}"; do
    git cat-file -e "$commit:$p" 2>/dev/null || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'error: %s does not look like a tree this project can patch.\n' "$commit" >&2
    printf 'Missing from it:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf '\nThe most likely cause is pinning to a release tag older than the compiler\n' >&2
    printf 'open sourcing. mojo/v1.0.0 is one of those. Pin to a main commit instead.\n' >&2
    exit 1
  fi
}
