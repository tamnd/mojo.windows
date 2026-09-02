#!/usr/bin/env bash
# CI gate. Verifies the overlay is internally consistent and still lines up with the pin.
# Runs on every pull request. Keep it fast and keep it strict, this is the thing that stops
# the overlay rotting.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git
need python3

fail=0
note() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

COUNT="$(overlay_count)"
info "$COUNT files in the overlay"

# 1. The manifest and the files under overlay/ have to agree with each other. A file
#    listed but missing breaks sync.sh, and a file present but unlisted is worse, because
#    it looks like it is being applied and is not.
if [ "$COUNT" -gt 0 ]; then
  listed="$(mktemp)"
  present="$(mktemp)"
  trap 'rm -f "$listed" "$present"' EXIT

  while IFS=$'\t' read -r state blob path; do
    case "$state" in
      edit|new)
        printf '%s\n' "$path" >> "$listed"
        [ -f "$OVERLAY_DIR/$path" ] || note "$path is in the manifest but overlay/$path does not exist"
        ;;
      delete)
        [ -f "$OVERLAY_DIR/$path" ] && note "$path is marked delete but overlay/$path exists"
        ;;
    esac
    case "$state" in
      edit|delete) [ "$blob" = "-" ] && note "$path is marked $state but has no upstream blob recorded" ;;
      new) [ "$blob" = "-" ] || note "$path is marked new but has an upstream blob recorded" ;;
    esac
    case "$path" in
      /*|*..*) note "$path is not a plain relative path" ;;
    esac
  done < <(manifest_rows)

  LC_ALL=C sort -o "$listed" "$listed"
  if [ "$(LC_ALL=C uniq -d < "$listed" | grep -c . || true)" -ne 0 ]; then
    note "the manifest lists the same path more than once"
  fi

  ( cd "$OVERLAY_DIR" && find . -type f ! -name MANIFEST | sed 's|^\./||' ) | LC_ALL=C sort > "$present"
  if ! extra="$(LC_ALL=C comm -13 "$listed" "$present")" || [ -n "$extra" ]; then
    printf '%s\n' "$extra" >&2
    note "those files are under overlay/ but not in the manifest, so sync.sh will not apply them"
  fi
fi

# 2. Nothing in the overlay may leak private infrastructure. Host names and addresses stay
#    out of this repository, always. The specific names are deliberately not written down
#    here, because writing them down would itself put them in a public repository. Set
#    PRIVATE_HOST_PATTERN to an extended regex to check for them, which CI does from a
#    repository secret. Without it we still catch the generic shapes.
if [ "$COUNT" -gt 0 ]; then
  if grep -rnE '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' "$OVERLAY_DIR"; then
    note "the overlay contains a private IP address"
  fi
  if grep -rnE 'BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|ssh-(rsa|ed25519) AAAA' "$OVERLAY_DIR"; then
    note "the overlay contains key material"
  fi
  if grep -rnE '<<<<<<< |>>>>>>> ' "$OVERLAY_DIR"; then
    note "the overlay contains conflict markers"
  fi
  if [ -n "${PRIVATE_HOST_PATTERN:-}" ] && grep -rniE "$PRIVATE_HOST_PATTERN" "$OVERLAY_DIR"; then
    note "the overlay references private infrastructure"
  fi
fi

# 3. The overlay must line up with the pin, and the only honest way to check that is to
#    fetch the pin and look. This is the expensive check, so it goes last.
if [ "${SKIP_APPLY:-0}" != "1" ]; then
  out="$("$REPO_ROOT/scripts/sync.sh" 2>&1)" || { printf '%s\n' "$out" >&2; note "sync.sh failed"; }
  printf '%s\n' "$out"
  # sync.sh applies the overlay whatever happens and warns about drift rather than
  # stopping, because a developer with a half rebased tree still wants a tree. CI wants
  # the opposite, so the warning is an error here.
  if printf '%s' "$out" | grep -q 'the pin has moved under'; then
    note "upstream has changed files the overlay owns, reconcile them and run scripts/refresh.sh"
  fi
fi

if [ "$fail" -ne 0 ]; then
  info "overlay check failed"
  exit 1
fi
info "overlay check passed"
