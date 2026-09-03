#!/usr/bin/env bash
# Turns a tier number from test-tiers.txt into the target patterns for it, and by default
# runs them.
#
#   scripts/test-tier.sh 0                        # run tier 0 for the host
#   scripts/test-tier.sh 1 --config=windows ...   # anything after the tier goes to Bazel
#   scripts/test-tier.sh 1 --print                # just the patterns, one per line
#
# The point of this is that "tier 1 is green" is a claim someone can check in one command,
# where "eighty one percent of the suite passes" is a number nobody can do anything with.
# See the header of test-tiers.txt for what the tiers mean and why they exist.
#
# Bazel is not on PATH in this tree. `./bazelw` inside the upstream checkout is the only
# entry point, so this runs from there, which also means the target patterns below are
# already in the right workspace.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TIERS_FILE="$REPO_ROOT/test-tiers.txt"

[ "$#" -ge 1 ] || die "usage: $(basename "$0") <tier> [--print | bazel args...]"

tier="$1"
shift
case "$tier" in
  0 | 1 | 2 | 3) ;;
  *) die "tier must be 0, 1, 2 or 3, and was '$tier'" ;;
esac

[ -f "$TIERS_FILE" ] || die "$TIERS_FILE does not exist"

# The most specific match wins, and Bazel already knows how to subtract one pattern from
# another, so the work here is only to decide which negations to emit. A pattern belongs
# to the output if it is in this tier. A pattern belongs as a negation if it is in some
# other tier and sits underneath one of this tier's patterns, which for a bare label means
# its package is under a `/...` prefix.
#
# Bazel wants the positives first. A negative pattern only subtracts from what came before
# it on the command line, so a `-//a:b` ahead of `//a/...` subtracts from nothing and the
# target comes back anyway.
patterns="$(python3 - "$TIERS_FILE" "$tier" <<'PY'
import sys

path, want = sys.argv[1], sys.argv[2]
rows = []
for raw in open(path, encoding="utf-8"):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    parts = line.split()
    if len(parts) != 2:
        sys.exit("error: bad tiers line: %s" % raw.rstrip())
    rows.append((parts[0], parts[1]))

seen = {}
for tier, pattern in rows:
    if pattern in seen:
        sys.exit("error: %s is listed twice" % pattern)
    seen[pattern] = tier

mine = [p for t, p in rows if t == want]
prefixes = [p[: -len("...")] for p in mine if p.endswith("/...")]


def covered(pattern):
    # A bare label like //a/b:c is under the prefix //a/b/ once the colon is a slash.
    package = pattern.split(":", 1)[0] + "/"
    return any(package.startswith(prefix) for prefix in prefixes)


out = list(mine)
out += ["-" + p for t, p in rows if t != want and covered(p)]
print("\n".join(out))
PY
)"

[ -n "$patterns" ] || die "no patterns are in tier $tier"

if [ "${1:-}" = "--print" ]; then
  printf '%s\n' "$patterns"
  exit 0
fi

[ -x "$CHECKOUT/bazelw" ] || die "$CHECKOUT/bazelw does not exist, run scripts/sync.sh first"

# The `--` is not optional. A negative pattern starts with a dash, and the wrapper in front
# of Bazel reads it as an option it does not know, which comes out as "failed to parse test
# options: Invalid options syntax" and names the target.
#
# Word splitting is the point: each line is one argument.
# shellcheck disable=SC2086
cd "$CHECKOUT" && exec ./bazelw test "$@" -- $patterns
