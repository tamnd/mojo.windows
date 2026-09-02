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
