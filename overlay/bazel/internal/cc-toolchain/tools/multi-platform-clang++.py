#!/usr/bin/env python3
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
"""Runs the clang++ belonging to the machine that is running the build.

The C++ half of multi-platform-clang.py, kept as a separate file because a
cc_tool names one file and Bazel gives it no way to say which of two compilers
it stands for. The duplication is the same duplication the bash pair had.

See multi-platform-clang.py for why this is Python and why the interpreter is
the system one.
"""

import os
import platform
import subprocess
import sys

ARCHIVE_PREFIX = "+http_archive+clang-"


# What an executable in the clang archive is called on this machine. The archive
# for Windows is the stock LLVM release and ships bin/clang.exe, and the three
# Unix ones ship bin/clang, so the name has to be built rather than written.
EXE = ".exe" if os.name == "nt" else ""


def host_platform() -> str:
    """Names the clang archive for the machine running this build."""
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux-" + platform.machine()
    if sys.platform == "win32":
        # x86_64 without asking, because it is the only Windows execution
        # platform the cc toolchain registers and the only one bazelw will
        # start on, so a machine that got this far is one.
        return "windows-x86_64"
    raise SystemExit(f"error: no clang archive for host '{sys.platform}'")


def clang_root() -> str:
    """Finds the unpacked clang archive, wherever this was run from."""
    name = ARCHIVE_PREFIX + host_platform()
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.join(script_dir, *([os.pardir] * 4))
    candidates = [
        os.path.join(os.getcwd(), "external", name),
        # File paths in some golang compiles
        os.path.join(repo_root, "external", name),
        # File paths in tests differ
        os.path.join(repo_root, os.pardir, name),
    ]
    for candidate in candidates:
        if os.path.isdir(candidate):
            return candidate
    return candidates[-1]


def main(argv: list[str]) -> int:
    """Runs clang++, then stamps the parse header file if one was asked for."""
    clang = os.path.join(clang_root(), "bin", "clang++" + EXE)
    parse_header = os.environ.get("PARSE_HEADER")

    # There is nothing to do afterwards in the common case, so hand the process
    # over instead of holding a second one open for every compile in the tree.
    if not parse_header and os.name == "posix":
        os.execv(clang, [clang, *argv])

    status = subprocess.run([clang, *argv]).returncode
    if status != 0:
        return status

    if parse_header:
        with open(parse_header, "a"):
            pass
        os.utime(parse_header, None)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
