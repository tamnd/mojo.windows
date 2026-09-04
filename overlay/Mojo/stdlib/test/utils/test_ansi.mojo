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

from std.sys._io import stdout
from std.utils._ansi import Color, Text, _use_color

from std.testing import TestSuite, assert_equal, assert_false, assert_true

# Whether output is coloured depends on where it is going, and a test cannot
# choose that, so nothing here asserts which of the two answers is right. What
# it asserts is that everything agrees on the same answer, because the way this
# goes wrong is one part of the library deciding there is a terminal and another
# deciding there is not, and the result is escape sequences in a file.
#
# Under any test runner the answer is no, since the output is being captured, so
# the branch that runs in practice is the one that checks a redirected file
# comes out clean.


def test_one_answer_everywhere() raises:
    var coloured = _use_color()
    assert_equal(String(Color.RED).byte_length() > 0, coloured)
    assert_equal(String(Color.END).byte_length() > 0, coloured)


def test_nothing_is_added_when_output_is_not_a_terminal() raises:
    if _use_color():
        return

    assert_equal(String(Text[Color.RED]("hello")), "hello")
    assert_equal(String(Color.GREEN), "")

    # `NONE` is the empty colour and stays empty either way, which is worth
    # pinning down because it is what a caller uses to ask for no colour at all.
    assert_equal(String(Color.NONE), "")


def test_the_sequence_is_closed_when_output_is_a_terminal() raises:
    if not _use_color():
        return

    var written = String(Text[Color.RED]("hello"))
    assert_true(written.startswith(String(Color.RED)))
    assert_true(written.endswith(String(Color.END)))
    assert_false(String(Color.RED) == String(Color.END))


def test_a_terminal_is_never_reported_for_output_that_is_captured() raises:
    """The regression this is really here for.

    On Windows the question is not whether the descriptor is a character
    device, because a pipe is one and so is the null device, and the answer to
    that question would put escape sequences into anything a shell redirects.
    """
    if not stdout.isatty():
        assert_false(_use_color())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
