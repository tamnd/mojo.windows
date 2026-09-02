#!/usr/bin/env bash
# Shared helpers. Source this, do not run it.
#
# These are consumed by the scripts that source this file, not by this file itself.
# shellcheck disable=SC2034

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$REPO_ROOT/upstream.lock"
PATCH_DIR="$REPO_ROOT/patches"
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

patch_count() {
  find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -type f 2>/dev/null | wc -l | tr -d ' '
}

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
