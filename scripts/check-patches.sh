#!/usr/bin/env bash
# CI gate. Verifies the patch series is well formed and applies cleanly at the pinned commit.
# Runs on every pull request. Keep it fast and keep it strict, this is the thing that stops
# the series rotting.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git
need python3

fail=0
note() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

COUNT="$(patch_count)"
info "$COUNT patches in the series"

# 1. Every patch must have a real subject and a sign off. A patch we cannot hand to a
#    reviewer as is has already lost most of its value.
for p in "$PATCH_DIR"/*.patch; do
  [ -e "$p" ] || break
  name="$(basename "$p")"
  grep -q '^Subject: ' "$p" || note "$name has no Subject line"
  grep -q '^Signed-off-by: ' "$p" || note "$name has no Signed-off-by line"
  grep -qE '^Subject: (\[PATCH[^]]*\] )?(build|compiler|runtime|stdlib|test|bazel|docs)(\([^)]+\))?: ' "$p" \
    || note "$name subject must start with one of build, compiler, runtime, stdlib, test, bazel, docs followed by a colon"
  if grep -qiE '^\+.*(FIXME: *rebase|<<<<<<<|>>>>>>>)' "$p"; then
    note "$name contains conflict markers or a rebase reminder"
  fi
done

# 2. Nothing in the series may leak private infrastructure. Host names and addresses stay
#    out of this repository, always. The specific names are deliberately not written down
#    here, because writing them down would itself put them in a public repository. Set
#    PRIVATE_HOST_PATTERN to an extended regex to check for them, which CI does from a
#    repository secret. Without it we still catch the generic shapes.
if [ "$COUNT" -gt 0 ]; then
  if grep -rnE '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' "$PATCH_DIR"; then
    note "the series contains a private IP address"
  fi
  if grep -rnE 'BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|ssh-(rsa|ed25519) AAAA' "$PATCH_DIR"; then
    note "the series contains key material"
  fi
  if [ -n "${PRIVATE_HOST_PATTERN:-}" ] && grep -rniE "$PRIVATE_HOST_PATTERN" "$PATCH_DIR"; then
    note "the series references private infrastructure"
  fi
fi

# 3. The series must actually apply. This is the expensive check, so it goes last.
if [ "${SKIP_APPLY:-0}" != "1" ]; then
  "$REPO_ROOT/scripts/sync.sh" || note "the series does not apply at the pinned commit"
fi

if [ "$fail" -ne 0 ]; then
  info "patch check failed"
  exit 1
fi
info "patch check passed"
