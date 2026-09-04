#!/usr/bin/env bash
# CI gate. Runs Bazel analysis for the Windows target and fails if the set of targets that
# do not analyze has changed.
#
#   scripts/check-windows-analysis.sh
#
# Analysis only, so nothing compiles and nothing links. That is the point. A full Windows
# build is hours of compiler and LLVM work and needs a sysroot, and neither is affordable
# on a hosted runner, but the failures this catches are not compile failures. They are
# select() arms with no Windows entry, toolchain registrations that stopped resolving, and
# constraints that drifted, and all of those show up during analysis in about ten seconds.
# That is most of the value of a cross build lane for none of the cost.
#
# No sysroot is needed. The sysroot-windows repository rule is written to produce a valid
# but empty repository when MOJO_WINDOWS_SYSROOT is unset, which is enough to configure
# actions even though it is nowhere near enough to run them.
#
# The comparison is against windows-analysis-allowlist.txt rather than against zero,
# because the set is not empty yet. A target that fails and is not listed is a regression.
# A target that is listed and passes means somebody fixed something and did not delete the
# line, and that fails too, because an allowlist nobody prunes stops meaning anything.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need python3

ALLOWLIST="$REPO_ROOT/windows-analysis-allowlist.txt"

[ -d "$CHECKOUT" ] || die "$CHECKOUT does not exist, run scripts/sync.sh first"
[ -f "$ALLOWLIST" ] || die "$ALLOWLIST does not exist"

# The tier patterns include negations, which look like options to the bazelisk wrapper
# unless everything after the command is put behind a --.
mapfile -t patterns < <("$REPO_ROOT/scripts/test-tier.sh" 0 --print
                        "$REPO_ROOT/scripts/test-tier.sh" 1 --print)
[ "${#patterns[@]}" -gt 0 ] || die "test-tier.sh produced no patterns"

# The compiler itself goes in on top of the tiers. It is the one target whose Windows
# analysis breaking would be invisible in a list of standard library tests.
targets=("//Mojo/tools/mojo" "${patterns[@]}")

info "analyzing ${#targets[@]} target patterns for the Windows platform"

log="$(mktemp)"
actual="$(mktemp)"
expected="$(mktemp)"
trap 'rm -f "$log" "$actual" "$expected"' EXIT

# A shared repository cache is worth an order of magnitude on a fresh machine, and on CI
# it is the difference between this lane being cheap and it being a download every time.
# Left unset locally, where Bazel's own default is already the right answer.
extra=()
if [ -n "${MOJO_WIN_BAZEL_REPO_CACHE:-}" ]; then
  mkdir -p "$MOJO_WIN_BAZEL_REPO_CACHE"
  extra+=("--repository_cache=$MOJO_WIN_BAZEL_REPO_CACHE")
fi

# --keep_going so one broken package does not hide the rest, and the exit status is
# therefore not the signal. The failing set is.
(
  cd "$CHECKOUT"
  ./bazelw build --nobuild --keep_going \
    --config=build-mojo --config=windows \
    "${extra[@]}" \
    -- "${targets[@]}"
) > "$log" 2>&1 || true

# Bazel names each one in a warning as it gives up on it. The ERROR lines are not usable
# for this: a target can produce several of them, or none when the failure came from a
# dependency, so the warnings are the only place the complete set appears once each.
grep -oE "while analyzing target '[^']+'" "$log" \
  | sed "s/while analyzing target '//; s/'$//" \
  | sort -u > "$actual"

grep -vE '^\s*(#|$)' "$ALLOWLIST" | sort -u > "$expected"

new="$(comm -23 "$actual" "$expected")"
fixed="$(comm -13 "$actual" "$expected")"

if [ -z "$new" ] && [ -z "$fixed" ]; then
  info "$(wc -l < "$actual" | tr -d ' ') known failures, no change"
  exit 0
fi

if [ -n "$new" ]; then
  printf '\nFAIL: these targets no longer analyze for Windows:\n\n' >&2
  printf '%s\n' "$new" | sed 's/^/  /' >&2
  printf '\nWhat Bazel said:\n\n' >&2
  grep -E '^ERROR' "$log" | sed 's/^/  /' >&2
  printf '\nIf the target genuinely does not apply on Windows, mark it incompatible\n' >&2
  printf 'rather than adding it to the allowlist. That list is for things meant to\n' >&2
  printf 'work that do not yet.\n' >&2
fi

if [ -n "$fixed" ]; then
  printf '\nFAIL: these are in windows-analysis-allowlist.txt and now analyze fine:\n\n' >&2
  printf '%s\n' "$fixed" | sed 's/^/  /' >&2
  printf '\nDelete those lines. The list is only useful while it is accurate.\n' >&2
fi

exit 1
