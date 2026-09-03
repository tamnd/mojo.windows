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
#   MOJO_WINDOWS_TEST_ENV        NAME=VALUE lines to set on the far side, one per line
#   MOJO_WINDOWS_TEST_VERBOSE    set to anything to print the environment being set
#
# One variable goes the other way. When the program handed to this script is not a Windows
# binary it is run where it is, with MOJO_WINDOWS_RUN set to the path of this script, so a
# test wrapper that has a Windows binary of its own to run can send that one across. See
# the passthrough below for why that is the right level for the decision.
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
#
# The wsl transport under bazel test needs three flags that are not obvious and that fail
# in ways which do not name WSL:
#
#   --strategy=TestRunner=local
#   --test_env=WSL_INTEROP --test_env=WSL_DISTRO_NAME
#
# The sandbox has /mnt/c read only, so staging into it fails with "mkdir: Read-only file
# system" and never reaches Windows. Interop is a vsock to a server on the Windows side
# and the two variables are how a process finds it, so without them the exec times out as
# "UtilAcceptVsock:273: accept4 failed 110" and looks like a broken binary.

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

# What --run_under gets is the test executable, and for about half the standard library
# suite that is not a Mojo binary. A mojo_test hands over its .exe and this script does the
# obvious thing with it. A mojo_filecheck_test hands over a Python program that runs a
# binary and pipes its output into FileCheck, and a lit test hands over llvm-lit. Both of
# those are py_test, and for a Windows target Bazel builds a py_test into a launcher .exe
# whose job is to find a python.exe and hand it a script. Copying that to a machine which
# has neither produces
#
#   python.exe: can't open file 'C:\...\test_negative_index_list.mojo.test'
#
# which is a report about this script dressed up as a report about the port. It was 109 of
# the 119 tier 0 and tier 1 failures.
#
# A launcher is recognised by the launch data Bazel appends to it, whose first key is
# binary_type, and the script it would have run sits beside it under the same name without
# the .exe. That script is an ordinary Python program, so it runs here, and it gets
# MOJO_WINDOWS_RUN pointing back at this script. A wrapper with a Windows binary among the
# things it runs reads that and sends that one across itself, which is the level the
# decision belongs at: the wrapper knows which of them was built for Windows, and by the
# time a path reaches this script that information is gone.
#
# lit tests get the same passthrough for a different reason and want no more than it. They
# drive the mojo driver at test time and it targets the host, so a lit test is a host test
# under every configuration, and running it here is what it was always doing.
host_stub="${binary%.exe}"
if [ "$(head -c 2 "$binary")" != "MZ" ] ||
  { [ -f "$host_stub" ] && tail -c 8192 "$binary" | grep -aq 'binary_type='; }; then
  [ -f "$host_stub" ] || host_stub="$binary"
  self="$REPO_ROOT/scripts/$(basename "${BASH_SOURCE[0]}")"
  export MOJO_WINDOWS_RUN="$self"
  exec "$host_stub" "$@"
fi

# A test that reads a file needs that file, and Bazel does not put it next to the binary.
# It writes a runfiles manifest instead, mapping the path a test will ask for to wherever
# the file actually is, and on Linux the test runner points the process at that. Nothing
# points a Windows process at anything, so the paths have to be rebuilt on the far side or
# every test that opens its own data fails on a missing file and looks like a porting bug.
#
# The entries under _main are the binary, the DLLs beside it, and the data, which is nine
# files for a stdlib test. They go into a directory belonging to this run and are deleted
# with it. The rest of the manifest belongs to external repositories, and for a test that
# touches Python that is a whole CPython for Windows, 2765 entries and about five megabytes.
# Those are staged as well, once per machine rather than once per test, and stage_external
# below is where that happens and why it happens the way it does.
#
# Where that manifest is depends on who is running this, and there are three answers. Bazel
# sets RUNFILES_MANIFEST_FILE when the tree is manifest only. Otherwise it builds a real
# symlink tree, names it in RUNFILES_DIR and puts a MANIFEST of the same format inside, and
# that is the case under --run_under, where the path handed over is already inside the tree
# and has no manifest beside it. Naming bazel-bin/.../foo.exe yourself is the third, and
# that one does have a sibling.
#
# Only the third was being looked at, so every test run through --run_under fell through to
# the no manifest branch, which stages the executable and the libraries and nothing else.
# The test then ran with its data absent and reported a missing file, which reads like path
# handling on Windows and is not. Falling back says so now rather than doing it quietly.
manifest=""
for candidate in \
  "${RUNFILES_MANIFEST_FILE:-}" \
  "${RUNFILES_DIR:+$RUNFILES_DIR/MANIFEST}" \
  "$binary.runfiles_manifest"; do
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    manifest="$candidate"
    break
  fi
done

run_rel="$exe"
if [ -n "$manifest" ]; then
  run_rel="$(awk -v exe="$exe" '
    $1 ~ /^_main\// {
      n = split($1, parts, "/")
      if (parts[n] == exe) { sub(/^_main\//, "", $1); print $1; exit }
    }' "$manifest")"
  [ -n "$run_rel" ] || die "$exe is not listed in $manifest"
else
  info "no runfiles manifest for $exe, so only it and the libraries beside it are staged"
fi

# Copies everything the binary needs into a directory, keeping the shape the test expects
# to find rather than flattening it, because the paths in the test are relative.
stage_into() {
  local root="$1"
  mkdir -p "$root"
  if [ -n "$manifest" ]; then
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
      # A tree artifact is one manifest entry and a directory on disk, so the recursive
      # copy is not optional even though almost every entry is a single file.
      cp -RL "$src" "$root/$rel"
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

# Everything in the manifest that is not under _main belongs to an external repository, and
# Bazel points at those with paths that are relative to the runfiles root. A test that uses
# Python gets MOJO_PYTHON_LIBRARY set to something of this shape:
#
#   ../rules_python++python+python_3_13_x86_64-pc-windows-msvc/python313.dll
#
# The run at the bottom of this script happens with the current directory set to the staged
# tree, which is standing in for the runfiles _main directory, so the parent of that tree is
# where an external repository has to land for a path like that to resolve by itself. That
# is the whole trick, and the reason it is worth preferring to rewriting the variable: the
# paths Bazel wrote are already correct, they were just pointing at nothing.
#
# Staged once per machine rather than once per test, because 2765 files is not something to
# copy 235 times. Once per machine means two tests can want it at the same moment, and the
# lock directory settles that: mkdir is the one filesystem operation that succeeds for
# exactly one caller and tells that caller it won. The stamp beside the lock records how
# many entries were copied, so a later test that needs more of the same repository stages
# the rest and one that needs fewer does nothing at all.
#
# The staged tree is left behind on purpose. It is the cache, and deleting it at the end of
# a run would mean paying for the copy again at the start of the next one. Nothing prunes
# it either, and a repository name carries its version, so a staging directory that has seen
# a few upstream pins is worth deleting by hand once in a while.
#
# Not all of it, though. The external half of the manifest for the standard library suite is
# 719 megabytes, and most of that is sources for tools that run on this side and never go
# anywhere near Windows. What makes an external file reachable from a Windows process at all
# is a variable pointing at it, since there is no runfiles library on that side to look
# anything up, so a repo is staged when something in the environment about to be set points
# into it and not otherwise. That comes to 125 megabytes for tier 0 and tier 1, and 588 once
# tier 2 has asked for five Windows CPython trees.
#
# Points into it means the ../repo/ spelling specifically, which is how Bazel writes a path
# that is relative to the runfiles root, and is the only spelling that can come out right on
# the far side. A variable holding an absolute Linux path to the same repository is for a
# tool running on this side and staging what it names would be so many megabytes for
# nothing.
#
# A test that reaches an external file some other way would report it as missing, and the
# answer then is to widen this rather than to go back to copying everything.

external_repos() {
  [ -n "$manifest" ] || return 0
  local repo value
  while read -r repo; do
    for value in ${env_values[@]+"${env_values[@]}"}; do
      case "$value" in
        "../$repo/"* | *"/../$repo/"*)
          printf '%s\n' "$repo"
          break
          ;;
      esac
    done
  done < <(awk '{
    if ($1 ~ /^_main\//) next
    slash = index($1, "/")
    if (slash > 1) print substr($1, 1, slash - 1)
  }' "$manifest" | sort -u)
}

external_count() {
  awk -v prefix="$1/" 'index($1, prefix) == 1' "$manifest" | wc -l | tr -d ' '
}

# An entry with no source is a file Bazel wants created empty rather than copied, which is
# most of the __init__.py in a Python tree. Skipping those would read later as a module that
# does not exist rather than as a file that does not exist.
copy_external() {
  local repo="$1" root="$2" dest src
  while read -r dest src; do
    case "$dest" in
      "$repo"/*) ;;
      *) continue ;;
    esac
    mkdir -p "$root/$(dirname "$dest")"
    if [ -z "$src" ]; then
      : >"$root/$dest"
    elif [ -e "$src" ]; then
      cp -RL "$src" "$root/$dest"
    fi
  done <"$manifest"
}

# Only ever one at a time, since the repositories are staged one after another, so a single
# name is enough to remember what has to be given back if this exits early.
lock_held=""
lock_host=""

release_lock() {
  [ -n "$lock_held" ] || return 0
  if [ -n "$lock_host" ]; then
    # shellcheck disable=SC2029
    ssh "$lock_host" "rmdir \"$lock_held\"" >/dev/null 2>&1 || true
  else
    rmdir "$lock_held" 2>/dev/null || true
  fi
  lock_held=""
}

# Ten minutes, which is longer than the copy has ever taken and short enough that a lock
# left behind by a killed run says so rather than hanging the suite for good.
lock_timeout=600

stage_external() {
  local parent="$1" repo want have lock stamp waited
  for repo in $(external_repos); do
    stamp="$parent/.mojo-external-$repo"
    lock="$parent/.mojo-lock-$repo"
    want="$(external_count "$repo")"
    waited=0
    while true; do
      have="$(cat "$stamp" 2>/dev/null || echo 0)"
      if [ "$have" -ge "$want" ]; then
        break
      fi
      if mkdir "$lock" 2>/dev/null; then
        lock_held="$lock"
        info "staging $want files of $repo, once for every test on this machine"
        copy_external "$repo" "$parent"
        printf '%s\n' "$want" >"$stamp"
        release_lock
        break
      fi
      waited=$((waited + 1))
      [ "$waited" -lt "$lock_timeout" ] ||
        die "waited ten minutes for $lock, remove it if nothing is holding it"
      sleep 1
    done
  done
}

# Same shape over ssh, with the stamp and the lock on the Windows side because two build
# hosts can be pointed at one test machine. The copy is made here first and sent as a whole
# directory, since scp of 2765 separate files would be 2765 round trips.
stage_external_remote() {
  local host="$1" parent="$2" repo want have lock stamp waited tmp
  for repo in $(external_repos); do
    stamp="$parent\\.mojo-external-$repo"
    lock="$parent\\.mojo-lock-$repo"
    want="$(external_count "$repo")"
    waited=0
    while true; do
      # shellcheck disable=SC2029
      have="$(ssh "$host" "type \"$stamp\"" 2>/dev/null | tr -dc '0-9')"
      if [ -n "$have" ] && [ "$have" -ge "$want" ]; then
        break
      fi
      # shellcheck disable=SC2029
      if ssh "$host" "mkdir \"$lock\"" >/dev/null 2>&1; then
        lock_host="$host"
        lock_held="$lock"
        info "staging $want files of $repo, once for every test on $host"
        tmp="$(mktemp -d)"
        copy_external "$repo" "$tmp"
        scp -q -r "$tmp/$repo" "$host:${parent//\\//}/"
        rm -rf "$tmp"
        # No space before the redirection, which cmd would otherwise write into the file.
        # shellcheck disable=SC2029
        ssh "$host" "echo $want>\"$stamp\"" >/dev/null
        release_lock
        break
      fi
      waited=$((waited + 1))
      [ "$waited" -lt "$lock_timeout" ] ||
        die "waited ten minutes for $lock on $host, remove it if nothing is holding it"
      sleep 1
    done
  done
}

# A Bazel test target can declare environment variables, and the test that reads one is
# entitled to find it there. Nothing crosses to the Windows side by itself: the ssh
# transport starts a fresh cmd, and WSL hands a Windows process only the variables named
# in WSLENV. So the ones that should travel are collected here and set on the far side by
# whichever transport is in use.
#
# Which ones should travel is the only interesting question, and the answer depends on who
# is running this. Under --run_under the environment is Bazel's: it scrubs the client's
# shell and builds a small one from the target's env attribute, --test_env and its own
# bookkeeping. Taking all of that minus a deny list is safe and is what happens below.
#
# Run by hand from a terminal the environment is a person's login shell, which on a
# developer machine holds API tokens, cloud credentials and whatever else is exported in a
# profile. Sweeping that to another machine over ssh is not a thing this script should do
# quietly, and no test needs it, so outside Bazel nothing is swept and MOJO_WINDOWS_TEST_ENV
# names what crosses. TEST_SRCDIR is the test for which situation this is, because Bazel
# sets it for every test it runs and nothing else does.
declare -a env_names=() env_values=()

put_env() {
  local name="$1" value="$2" i
  for i in "${!env_names[@]}"; do
    if [ "${env_names[i]}" = "$name" ]; then
      env_values[i]="$value"
      return
    fi
  done
  env_names+=("$name")
  env_values+=("$value")
}

# Bazel's own variables are listed one at a time rather than caught with a TEST_ prefix,
# which would be shorter and would also drop TEST_MYVAR, the variable this entire section
# exists to deliver. Within Bazel's environment a name that is new and unrecognised gets
# passed along, which is the right way round to be wrong: an extra variable on the far
# side costs nothing, and a missing one is the silent failure being fixed.
if [ -n "${TEST_SRCDIR:-}" ]; then
  while IFS='=' read -r -d '' name value; do
    case "$name" in
      # Not something a Windows process could name, whatever it is.
      '' | [0-9]* | *[!A-Za-z0-9_]*) continue ;;
      # The POSIX shell's and the system's.
      PATH | HOME | PWD | OLDPWD | SHELL | SHLVL | USER | LOGNAME | HOSTNAME) continue ;;
      TERM | TZ | TMPDIR | TMP | TEMP | LANG | LC_* | IFS | _) continue ;;
      EDITOR | PAGER | SSH_* | XDG_* | BASH_* | WSL* | MOJO_WINDOWS_*) continue ;;
      HOSTTYPE | OSTYPE | MACHTYPE | LS_COLORS | COLORTERM | NAME) continue ;;
      # WSL's, describing a Linux desktop session that no Windows process shares.
      DISPLAY | WAYLAND_DISPLAY | PULSE_SERVER | PULSE_COOKIE) continue ;;
      DBUS_SESSION_BUS_ADDRESS) continue ;;
      # Bazel's. TEST_TMPDIR is here because it is replaced later rather than dropped.
      TEST_SRCDIR | TEST_TMPDIR | TEST_BINARY | TEST_NAME | TEST_TARGET) continue ;;
      TEST_SIZE | TEST_TIMEOUT | TEST_WORKSPACE | TEST_RANDOM_SEED) continue ;;
      TEST_RUN_NUMBER | TEST_TOTAL_SHARDS | TEST_SHARD_INDEX) continue ;;
      TEST_SHARD_STATUS_FILE | TEST_PREMATURE_EXIT_FILE) continue ;;
      TEST_INFRASTRUCTURE_FAILURE_FILE | TEST_WARNINGS_OUTPUT_FILE) continue ;;
      TEST_LOGSPLITTER_OUTPUT_FILE | TEST_UNDECLARED_OUTPUTS_DIR) continue ;;
      TEST_UNDECLARED_OUTPUTS_MANIFEST | TEST_UNDECLARED_OUTPUTS_ANNOTATIONS) continue ;;
      TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR | XML_OUTPUT_FILE) continue ;;
      RUNFILES_DIR | RUNFILES_MANIFEST_FILE | RUNFILES_MANIFEST_ONLY) continue ;;
      JAVA_RUNFILES | PYTHON_RUNFILES | RUN_UNDER_RUNFILES) continue ;;
      BAZEL_TEST | GTEST_TMP_DIR) continue ;;
    esac
    put_env "$name" "$value"
  done < <(env -0)
fi

# One NAME=VALUE per line, so a value is free to contain spaces, an equals sign or a
# semicolon, none of which are unusual in a path.
if [ -n "${MOJO_WINDOWS_TEST_ENV:-}" ]; then
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    case "$pair" in
      *=*) put_env "${pair%%=*}" "${pair#*=}" ;;
      *) die "MOJO_WINDOWS_TEST_ENV holds NAME=VALUE lines, and this one is '$pair'" ;;
    esac
  done <<<"$MOJO_WINDOWS_TEST_ENV"
fi

# A variable that quietly does not arrive is the failure this section exists to fix, so
# there is a way to see what was sent without reading the transport's quoting. Off by
# default because under Bazel this would print on every test.
report_env() {
  [ -n "${MOJO_WINDOWS_TEST_VERBOSE:-}" ] || return 0
  local i
  info "setting ${#env_names[@]} variables on the Windows side"
  for i in "${!env_names[@]}"; do
    info "  ${env_names[i]}=${env_values[i]}"
  done
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
    ssh "$host" "mkdir \"$remote\\_tmp\"" >/dev/null

    # Bazel gives a test a scratch directory of its own and tells it where through
    # TEST_TMPDIR, and whatever it was pointing at was a Linux path. This one is a
    # Windows path, it goes away with the rest of the staging directory, and it means a
    # test writing a temporary file writes it somewhere rather than into the root of C.
    put_env TEST_TMPDIR "$remote\\_tmp"

    # Kept as a trap rather than a line at the end, because a test that fails is the
    # normal case here and leaving a directory behind on every red run adds up.
    # shellcheck disable=SC2029,SC2317,SC2329
    cleanup() { ssh "$host" "rmdir /s /q \"$remote\"" >/dev/null 2>&1 || true; }
    trap cleanup EXIT

    staged="$(mktemp -d)"
    trap 'rm -rf "$staged"; release_lock; cleanup' EXIT
    stage_into "$staged"
    scp -q -r "$staged"/* "$host:$remote_scp/"
    stage_external_remote "$host" "$root"

    # cmd wants backslashes in a path it is being asked to execute, and the staged path
    # is several directories deep once there are runfiles in it.
    run_win="${run_rel//\//\\}"

    # set "NAME=VALUE" rather than set NAME=VALUE, which is the form that survives a
    # value with a space or an ampersand in it. A percent sign in a value is still a
    # percent sign to cmd and would be read as a variable reference, which is a real
    # limitation and not one worth an escaping layer until something hits it.
    report_env
    env_prefix=""
    for i in "${!env_names[@]}"; do
      env_prefix+="set \"${env_names[i]}=${env_values[i]}\" && "
    done

    set +e
    # shellcheck disable=SC2029
    ssh "$host" "cd \"$remote\" && $env_prefix.\\$run_win $*"
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
    trap 'rm -rf "$remote"; release_lock' EXIT
    stage_into "$remote"
    stage_external "$stage"
    chmod +x "$remote/$run_rel"

    need wslpath
    mkdir -p "$remote/_tmp"
    put_env TEST_TMPDIR "$(wslpath -w "$remote/_tmp")"

    # WSL interop does not hand a Windows process the Linux environment. Exporting a
    # variable here is not enough and not close to enough: cmd.exe started from this side
    # prints back the literal %NAME% for anything that was only exported. WSLENV is the
    # list of names that do cross, colon separated, and a name in it with no trailing
    # flags crosses with its value exactly as it is. That last part matters, because the
    # flag that would otherwise be tempting, /p, translates the value as a path, and a
    # TEST_TMPDIR already spelled the Windows way would come out mangled.
    #
    # Whatever WSLENV already held is kept in front rather than overwritten, since the
    # session may be forwarding something of its own and this script has no business
    # deciding that it should not.
    report_env
    for i in "${!env_names[@]}"; do
      export "${env_names[i]}=${env_values[i]}"
      WSLENV="${WSLENV:+$WSLENV:}${env_names[i]}"
    done
    export WSLENV

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
