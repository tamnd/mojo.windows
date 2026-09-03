# ===----------------------------------------------------------------------=== #
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
# ===----------------------------------------------------------------------=== #

"""Runs a mojo_binary and pipes its output through FileCheck.

This used to be a bash script, and bash is not something a Windows machine has.
Python is already a dependency of the build, so one implementation here serves
every platform that Bazel itself runs on.
"""

import os
import subprocess
import sys


def main() -> int:
    binary = os.environ["BINARY"]
    filecheck = os.environ["FILECHECK"]
    source = os.environ["SOURCE"]

    # The binary is the only part of this test that was built for Windows. FileCheck, the
    # `not` tool and this script all belong to the machine doing the build, so when the
    # test runs on Linux against a Windows target it is one process out of four that has
    # to travel. Bazel's --run_under cannot express that, since it wraps the test rather
    # than anything the test starts. run-on-windows.sh sets MOJO_WINDOWS_RUN when it has
    # been given something that is not a Windows binary, which is how it says "you know
    # which one of yours is, I do not".
    runner = os.environ.get("MOJO_WINDOWS_RUN", "")

    command = [binary, *sys.argv[1:]]
    if runner:
        command = [runner, *command]

    expect_crash = os.environ["EXPECT_CRASH"] == "1"
    if expect_crash and not runner:
        command = [os.environ["NOT"], "--crash", *command]
    elif os.environ["EXPECT_FAIL"] == "1":
        command = [os.environ["NOT"], *command]

    produce = subprocess.Popen(command, stdout=subprocess.PIPE)
    assert produce.stdout is not None
    check = subprocess.Popen([filecheck, source], stdin=produce.stdout)

    # The write end has to be closed here as well as in the child, or the check
    # process never sees end of input if the producer dies early.
    produce.stdout.close()

    check.wait()
    produce.wait()

    # `not --crash` asks whether the process died from a signal, and a Windows
    # process does not die from a signal. abort() is exit code 3 there, an access
    # violation is an NTSTATUS like 0xc0000409, and either one is a single byte by
    # the time ssh has handed it back. So a remote run checks that the binary
    # exited non zero and leaves the shape of the failure to FileCheck, which is
    # reading the assertion message and is where the content of these tests is.
    if expect_crash and runner:
        if produce.returncode == 0:
            print(
                "error: expected a crash and the binary exited 0",
                file=sys.stderr,
            )
            return 1
        return check.returncode

    # What bash reports for a pipeline under `set -o pipefail`, which is what the
    # script this replaces ran under: the status of the rightmost command that
    # failed. A binary that fails on its own is a test failure even when nothing
    # it managed to print upset FileCheck.
    return check.returncode or produce.returncode


if __name__ == "__main__":
    sys.exit(main())
