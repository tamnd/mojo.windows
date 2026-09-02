#!/bin/bash
##===----------------------------------------------------------------------===##
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##===----------------------------------------------------------------------===##

set -euo pipefail

if [[ $OSTYPE == darwin* ]]; then
  platform=macos
else
  platform="linux-$(uname -m)"
fi

clang_root="$PWD/external/+http_archive+clang-$platform"
# File paths in tests differ
if [[ ! -d "$clang_root" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$script_dir/../../../.."
  clang_root="$repo_root/../+http_archive+clang-$platform"
fi

readonly clang="$clang_root/bin/clang++"
readonly dsymutil="$clang_root/bin/dsymutil"

ifs_input=""
ifs_output=""
dsym_path=""
binary_path=""
linker_args=()
for arg in "$@"; do
  case "$arg" in
    --modular-ifs-input=*) ifs_input="${arg#*=}" ;;
    --modular-ifs-output=*) ifs_output="${arg#*=}" ;;
    --modular-dsym-path=*) dsym_path="${arg#*=}" ;;
    --modular-binary-path=*) binary_path="${arg#*=}" ;;
    *) linker_args+=("$arg") ;;
  esac
done

# rules_cc puts -Xlinker -rpath -Xlinker $ORIGIN/<dir> on the link line for every
# directory a target's dynamic dependencies live in. That is right on Linux, and the
# same thing with @loader_path is right on macOS, and on Windows it is not so much
# wrong as meaningless. $ORIGIN is an ELF concept that the dynamic loader expands at
# load time, PE has no equivalent, and lld-link has no -rpath at all. It warns about
# the option it does not know, and then reads the path that followed it as an input
# file, so what comes out is
#
#   lld-link: error: could not open '$ORIGIN/../_solib_win64/_USupport'
#
# which reads like a missing library rather than a flag nobody removed.
#
# Dropping them is the whole fix and not half of one. What an rpath is arranging,
# that a binary finds its shared libraries next to itself, is what the PE loader
# already does: its search order starts with the directory the executable was loaded
# from. There is nothing to translate the flag into. Windows still needs the DLLs to
# be in that directory rather than in a sibling _solib_ tree, but that is a runfiles
# layout question and not a link line one.
#
# This is done here, rather than by turning off the feature that generates them,
# because the feature cannot be turned off from outside rules_cc. rules_cc's own
# runtime_library_search_directories feature is not marked overridable, and it is
# pulled in wholesale by experimental_replace_legacy_action_config_features, which
# this toolchain enables. Overriding the legacy feature underneath it instead gets
# both into the toolchain under one name and fails analysis on every platform. The
# alternative was to copy rules_cc's twenty five entry feature list into our own
# BUILD file minus one line, and then keep that copy in step forever.
if [[ "${WINDOWS:-}" == "true" ]]; then
  filtered_args=()
  i=0
  while ((i < ${#linker_args[@]})); do
    arg="${linker_args[i]}"
    case "$arg" in
      # The generated form, four tokens: -Xlinker -rpath -Xlinker <path>.
      -Xlinker)
        if [[ "${linker_args[i + 1]:-}" == "-rpath" ]]; then
          i=$((i + 4))
          continue
        fi
        ;;
      # Not generated for this target today, but hand written -Wl,-rpath,DIR is the
      # spelling everywhere else in this tree, so it is cheaper to catch it here than
      # to find out later that one slipped through as a filename.
      -Wl,-rpath,* | -Wl,-rpath)
        i=$((i + 1))
        continue
        ;;
    esac
    filtered_args+=("$arg")
    i=$((i + 1))
  done
  linker_args=("${filtered_args[@]}")
fi

# Windows produces its interface library during the link rather than after it, so
# the flag has to go on before clang runs. An import library is what Windows has
# instead of the ELF stub shared object that llvm-ifs writes, and lld-link is the
# thing that knows how to make one. -Wl, because this is clang's GNU driver and a
# leading slash would otherwise be read as a path.
if [[ "${WINDOWS:-}" == "true" && "${BUILD_IFS:-}" == "yes" ]]; then
  if [[ -z "$ifs_output" ]]; then
    echo "error: interface library output path is required" >&2
    exit 1
  fi
  linker_args+=("-Wl,/IMPLIB:$ifs_output")
fi

"$clang" "${linker_args[@]}"

if [[ -n "$dsym_path" ]]; then
  "$dsymutil" -o "$dsym_path" "$binary_path"
fi

# Not Windows, which is finished by this point. llvm-ifs reads ELF or a text stub
# and nothing else, so handing it a PE file does not fail, it segfaults: it decides
# the DOS header is a YAML stub and parses it. Reported as "Got empty plain scalar"
# followed by a stack dump, on a link that had already succeeded.
if [[ "${WINDOWS:-}" != "true" && "${BUILD_IFS:-}" == "yes" ]]; then
  if [[ -z "$ifs_input" || -z "$ifs_output" ]]; then
    echo "error: interface library input and output paths are required" >&2
    exit 1
  fi

  if [[ $OSTYPE == darwin* ]]; then
    ifs_platform=mac
  elif [[ $(uname -m) == "x86_64" ]]; then
    ifs_platform=intel
  else
    ifs_platform=graviton
  fi

  ifs_root="$PWD/external/+http_archive+llvm-ifs/tools/$ifs_platform"

  if [[ "${MACOS:-}" == "true" ]]; then
    "$ifs_root/llvm-readtapi.stripped" -arch arm64 -extract "$ifs_input" -o "$ifs_output"
  else
    "$ifs_root/llvm-ifs.stripped" "$ifs_input" --output-elf="$ifs_output"
  fi
fi
