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

from std.subprocess import run
from std.sys import CompilationTarget

from std.testing import *


def test_run() raises:
    # Windows has no `ls`, and `dir` is a builtin of the command interpreter
    # rather than a program of its own. That is fine here, because `run` goes
    # through the interpreter on that side the same way it goes through a shell
    # everywhere else, so a builtin is as reachable as a program.
    comptime if CompilationTarget.is_windows():
        assert_not_equal(run("dir"), "")
    else:
        assert_not_equal(run("ls"), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
