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

from std.sys._fd import (
    fd_close,
    fd_dup,
    fd_isatty,
    fd_seek,
    fd_set_binary_mode,
)
from std.sys.info import CompilationTarget

from std.testing import TestSuite, assert_equal, assert_false, assert_raises

# A descriptor that is not open, and one no platform will ever hand out, so
# there is no machine on which this test is asking about a real file.
comptime _CLOSED = -1

# What a seek reports when it did not happen. `fd_seek` answers in 64 bits on
# every platform, so the failure value is written that way too.
comptime _SEEK_FAILED = Int64(-1)

# lseek from the start of the file. There is no constant for this in the
# standard library and the number is the same everywhere.
comptime _SEEK_SET = 0


def test_a_closed_descriptor_is_not_a_terminal() raises:
    """The one call that already had this covered, kept covered.

    This is what #190 was: on Windows the C runtime checked the descriptor,
    called its invalid parameter handler and the process was gone before
    `_isatty` returned, printing nothing and with an exit code nobody chose.
    """
    assert_false(fd_isatty(_CLOSED))


def test_a_closed_descriptor_fails_the_calls_that_take_one() raises:
    """Every one of these ends the process on Windows without the handler.

    The point is not the value each of them returns, which is the ordinary
    POSIX answer and not interesting. The point is that the test reaches the
    line after each call at all.
    """
    assert_equal(fd_close(_CLOSED), -1)
    assert_equal(fd_dup(_CLOSED), -1)
    assert_equal(fd_seek(_CLOSED, 0, _SEEK_SET), _SEEK_FAILED)

    comptime if CompilationTarget.is_windows():
        # POSIX has one mode, so there is nothing for this to fail at there and
        # it answers zero for any descriptor at all, open or not.
        assert_equal(fd_set_binary_mode(_CLOSED), -1)


def test_reading_a_closed_descriptor_raises() raises:
    """The same thing again, from as far outside as a user can stand.

    `FileDescriptor(-1)` and a read is the shortest program that reaches any of
    this without going near an underscore, and what it should do is raise.
    """
    var buffer = Array[UInt8, 8](fill=0)
    var fd = FileDescriptor(_CLOSED)
    with assert_raises(contains="Failed to read bytes."):
        _ = fd.read_bytes(Span(buffer))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
