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

    command = [binary, *sys.argv[1:]]
    if os.environ["EXPECT_CRASH"] == "1":
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

    # What bash reports for a pipeline under `set -o pipefail`, which is what the
    # script this replaces ran under: the status of the rightmost command that
    # failed. A binary that fails on its own is a test failure even when nothing
    # it managed to print upset FileCheck.
    return check.returncode or produce.returncode


if __name__ == "__main__":
    sys.exit(main())
