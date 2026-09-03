#!/usr/bin/env bash
# Runs a Windows binary that was built on Linux, on a Windows machine, and gives you
# back its exit code. Written to be handed to Bazel as --run_under, and usable on its
# own for the same job.
#
#   ./scripts/run-on-windows.sh bazel-bin/Mojo/test/abi-conformance/frames.exe
#
#   ./bazelw run --config=build-mojo --config=windows \
#     --repo_env=MOJO_WINDOWS_SYSROOT=... \
#     --run_under="$PWD/scripts/run-on-windows.sh" //Mojo/test/abi-conformance:frames
#
# Bazel cannot run a Windows test from a Linux execution host, and remote execution with
# a Windows executor is the architecturally right answer to that. This is not that. It is
# the forty lines that give a real Windows signal today, and it stops being worth keeping
# the moment its overhead is what is slowing anyone down.
#
# The machine it runs on comes from the environment and has no default, deliberately. No
# host name or address belonging to anyone's test machine goes in this repository.
#
#   MOJO_WINDOWS_TEST_HOST       ssh destination, such as user@host or an ssh config alias
#   MOJO_WINDOWS_TEST_DIR        staging directory on the Windows side, default C:\mojo-test
#   MOJO_WINDOWS_TEST_STAGE      a directory the Windows machine can see, for the wsl transport
#   MOJO_WINDOWS_TEST_TRANSPORT  ssh or wsl, inferred from the two above when unset
#
# Two transports because there are two situations, not because one of them was
# insufficiently thought about.
#
# ssh is the general one. Copy the binary and everything the loader will need next to it,
# run it, take the exit code, delete the directory.
#
# wsl is for when the Linux side doing the build is WSL on the same machine as the Windows
# side. There the file copy is a copy into /mnt/c and the run is just executing the .exe,
# because WSL interop starts it as a real Windows process and hands back its exit code.
# No network, no second set of credentials, and nothing about it is emulation: it is the
# same Windows kernel running the same PE that ssh would have started.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "$#" -ge 1 ] || die "usage: $(basename "$0") <binary> [args...]"

binary="$1"
shift
[ -f "$binary" ] || die "$binary does not exist"

# Bazel hands us a path inside the output tree, and the DLLs beside it are symlinks into
# the Bazel cache, so everything below dereferences rather than copies the link. PE has no
# rpath: the loader looks in the directory the executable is in and then in a short list of
# system directories, so the whole directory is what has to travel, not just the binary.
binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
source_dir="$(dirname "$binary")"
exe="$(basename "$binary")"

# A test that reads a file needs that file, and Bazel does not put it next to the binary.
# It writes a runfiles manifest instead, mapping the path a test will ask for to wherever
# the file actually is, and on Linux the test runner points the process at that. Nothing
# points a Windows process at anything, so the paths have to be rebuilt on the far side or
# every test that opens its own data fails on a missing file and looks like a porting bug.
#
# Only the entries under _main are copied. That is the binary, the DLLs beside it, and the
# data, which is nine files for a stdlib test. The rest of the manifest is a whole CPython
# for Windows, a couple of thousand files, and nothing that runs today reads any of it.
manifest="$binary.runfiles_manifest"
run_rel="$exe"
if [ -f "$manifest" ]; then
  run_rel="$(awk -v exe="$exe" '
    $1 ~ /^_main\// {
      n = split($1, parts, "/")
      if (parts[n] == exe) { sub(/^_main\//, "", $1); print $1; exit }
    }' "$manifest")"
  [ -n "$run_rel" ] || die "$exe is not listed in $manifest"
fi

# Copies everything the binary needs into a directory, keeping the shape the test expects
# to find rather than flattening it, because the paths in the test are relative.
stage_into() {
  local root="$1"
  mkdir -p "$root"
  if [ -f "$manifest" ]; then
    local dest src rel
    while read -r dest src; do
      case "$dest" in
        _main/*) ;;
        *) continue ;;
      esac
      if [ -z "$src" ] || [ ! -e "$src" ]; then
        continue
      fi
      rel="${dest#_main/}"
      mkdir -p "$root/$(dirname "$rel")"
      cp -L "$src" "$root/$rel"
    done < "$manifest"
  else
    # No manifest, so the binary is not a Bazel test and the DLLs beside it are all it
    # has. The abi conformance binaries are this shape.
    local lib
    cp -L "$binary" "$root/"
    for lib in "$source_dir"/*.dll; do
      [ -e "$lib" ] || continue
      cp -L "$lib" "$root/"
    done
  fi
}

transport="${MOJO_WINDOWS_TEST_TRANSPORT:-}"
if [ -z "$transport" ]; then
  if [ -n "${MOJO_WINDOWS_TEST_HOST:-}" ]; then
    transport=ssh
  elif [ -n "${MOJO_WINDOWS_TEST_STAGE:-}" ]; then
    transport=wsl
  else
    die "set MOJO_WINDOWS_TEST_HOST for the ssh transport or MOJO_WINDOWS_TEST_STAGE for the wsl one"
  fi
fi

# A name nothing else is using, so two runs against the same machine cannot land on each
# other. Not a mktemp, because the remote side is Windows and this has to be a name both
# sides can spell.
run_id="mojo-$$-$(date +%s)"

case "$transport" in
  ssh)
    need scp
    need ssh
    host="${MOJO_WINDOWS_TEST_HOST:-}"
    [ -n "$host" ] || die "MOJO_WINDOWS_TEST_HOST is not set"
    root="${MOJO_WINDOWS_TEST_DIR:-C:\\mojo-test}"
    remote="$root\\$run_id"
    # scp talks to the ssh subsystem rather than to cmd, and that side is happier with
    # forward slashes. cmd takes either but every backslash would need doubling through
    # the quoting, so the two spellings are worth keeping apart.
    remote_scp="${remote//\\//}"

    # Every remote command below expands on this side on purpose. The remote shell is
    # cmd, which does not know any of these names, so escaping them for it would send it
    # a variable reference it would leave as literal text.
    # shellcheck disable=SC2029
    ssh "$host" "mkdir \"$remote\"" >/dev/null

    # Kept as a trap rather than a line at the end, because a test that fails is the
    # normal case here and leaving a directory behind on every red run adds up.
    # shellcheck disable=SC2029,SC2317,SC2329
    cleanup() { ssh "$host" "rmdir /s /q \"$remote\"" >/dev/null 2>&1 || true; }
    trap cleanup EXIT

    staged="$(mktemp -d)"
    trap 'rm -rf "$staged"; cleanup' EXIT
    stage_into "$staged"
    scp -q -r "$staged"/* "$host:$remote_scp/"

    # cmd wants backslashes in a path it is being asked to execute, and the staged path
    # is several directories deep once there are runfiles in it.
    run_win="${run_rel//\//\\}"

    set +e
    # shellcheck disable=SC2029
    ssh "$host" "cd \"$remote\" && .\\$run_win $*"
    status=$?
    set -e
    exit "$status"
    ;;

  wsl)
    stage="${MOJO_WINDOWS_TEST_STAGE:-}"
    [ -n "$stage" ] || die "MOJO_WINDOWS_TEST_STAGE is not set"
    [ -d "$stage" ] || die "$stage does not exist"
    remote="$stage/$run_id"

    mkdir -p "$remote"
    trap 'rm -rf "$remote"' EXIT
    stage_into "$remote"
    chmod +x "$remote/$run_rel"

    set +e
    (cd "$remote" && "./$run_rel" "$@")
    status=$?
    set -e
    exit "$status"
    ;;

  *)
    die "unknown transport $transport, expected ssh or wsl"
    ;;
esac
