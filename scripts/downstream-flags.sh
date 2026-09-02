#!/usr/bin/env bash
# Print the Bazel flags that make a build identify itself as ours.
#
#   cd .upstream/modular
#   ./bazelw build --config=build-mojo $(../../scripts/downstream-flags.sh) //Mojo/tools/mojo
#
# The patch "compiler: let a downstream build identify itself in mojo --version"
# adds three build settings upstream, all empty by default. Empty means the build
# claims to be a Modular build, which for anything produced here would be a lie, so
# every binary this project ships has to be built with these set.
#
# The values are worked out rather than written down. The distributor is this
# repository, the build revision is this repository's HEAD, and the upstream commit
# comes from upstream.lock, which is the same commit the series is written against.
# Nothing here goes stale when the pin moves.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need git

ID="${MOJO_WIN_DOWNSTREAM_ID:-tamnd/mojo.windows}"

# Short HEAD of this repository, with a marker when the tree is dirty, because a
# binary built from uncommitted work should not claim to be a commit that exists.
BUILD="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
if [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]; then
  BUILD="$BUILD-dirty"
fi

printf -- '--//:downstream_id=%s\n' "$ID"
printf -- '--//:downstream_build=%s\n' "$BUILD"
printf -- '--//:downstream_upstream_commit=%s\n' "$(upstream_commit)"
