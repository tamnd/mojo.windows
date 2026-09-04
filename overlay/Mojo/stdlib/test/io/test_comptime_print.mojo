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

from std.testing import TestSuite, assert_equal

# Printing while the compiler is evaluating something. There is nothing to
# check at run time, because the message went to the compiler's output while
# this file was being built and is long gone by the time the test runs. What is
# being tested is that the file builds at all: the write underneath `print` is
# spelled one way for Windows and another way for everything else, and the
# interpreter only knows how to carry out a handful of calls, picked by name, so
# a name spelled for the target is a build failure as soon as the target is one
# the interpreter has never heard of.


def _counted() -> Int:
    print("printing from the comptime interpreter")
    return 5


def test_print_while_the_compiler_is_looking() raises:
    comptime counted = _counted()
    assert_equal(counted, 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
