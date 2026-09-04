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

from std.os.path import is_reserved
from std.sys.info import CompilationTarget

from std.testing import TestSuite, assert_false, assert_true


def test_nothing_is_reserved_on_unix() raises:
    comptime if CompilationTarget.is_windows():
        return

    # Every byte except the separator and the terminator is a legal name on
    # Unix, so a file called `nul.txt` or `com1` is an ordinary file.
    assert_false(is_reserved("nul.txt"))
    assert_false(is_reserved("com1"))
    assert_false(is_reserved("report."))
    assert_false(is_reserved("a<b>c"))
    assert_false(is_reserved(""))


def test_ordinary_names() raises:
    comptime if CompilationTarget.is_windows():
        assert_false(is_reserved("file.txt"))
        assert_false(is_reserved("C:\\dir\\file.txt"))
        assert_false(is_reserved("C:/dir/file.txt"))
        assert_false(is_reserved(""))
        assert_false(is_reserved("C:\\"))

        # `.` and `..` end in a dot without being a name that ends in a dot.
        assert_false(is_reserved("."))
        assert_false(is_reserved(".."))
        assert_false(is_reserved("a\\.\\b"))
        assert_false(is_reserved("a\\..\\b"))

        # A leading dot is an ordinary name and so is a name with a dot in the
        # middle of it.
        assert_false(is_reserved(".gitignore"))
        assert_false(is_reserved("a.b.c"))

        # These start with the letters of a device and are not one.
        assert_false(is_reserved("console"))
        assert_false(is_reserved("com0"))
        assert_false(is_reserved("com10"))
        assert_false(is_reserved("nula"))
        assert_false(is_reserved("lpt"))


def test_device_names() raises:
    comptime if CompilationTarget.is_windows():
        assert_true(is_reserved("con"))
        assert_true(is_reserved("PRN"))
        assert_true(is_reserved("Aux"))
        assert_true(is_reserved("nul"))
        assert_true(is_reserved("com1"))
        assert_true(is_reserved("COM9"))
        assert_true(is_reserved("lpt1"))
        assert_true(is_reserved("LPT9"))
        assert_true(is_reserved("conin$"))
        assert_true(is_reserved("CONOUT$"))

        # Windows reads a superscript port number as the digit it looks like,
        # so this is `COM1` written in a way that gets past a check on the
        # ASCII spelling alone.
        assert_true(is_reserved("com\u00b9"))
        assert_true(is_reserved("LPT\u00b3"))


def test_a_device_with_an_extension_is_still_the_device() raises:
    """The one that catches people out.

    `nul.txt` in a directory full of reports is the null device. Writing to it
    succeeds, reading from it gives nothing, and the file never appears.
    """
    comptime if CompilationTarget.is_windows():
        assert_true(is_reserved("nul.txt"))
        assert_true(is_reserved("C:\\reports\\nul.txt"))
        assert_true(is_reserved("com1.txt.gz"))

        # The spaces between the name and the extension go too.
        assert_true(is_reserved("nul .txt"))


def test_a_device_anywhere_in_the_path() raises:
    comptime if CompilationTarget.is_windows():
        # A directory is a name like any other, so a device in the middle is
        # reserved even though the last component is fine.
        assert_true(is_reserved("C:\\dir\\nul\\file.txt"))
        assert_true(is_reserved("C:/dir/con/file.txt"))


def test_trailing_dots_and_spaces() raises:
    """Names that arrive as a different name from the one that was written.

    Windows strips these on the way in, so `report.` reaches `report` while
    `split` and `basename` here still read the dot as part of the name. The two
    answers disagree and a caller that trusts the lexical one is wrong.
    """
    comptime if CompilationTarget.is_windows():
        assert_true(is_reserved("report."))
        assert_true(is_reserved("report "))
        assert_true(is_reserved("report.txt."))
        assert_true(is_reserved("C:\\dir\\report."))

        # In a directory name as well, where it is easier to miss.
        assert_true(is_reserved("C:\\dir. \\file.txt"))


def test_reserved_characters() raises:
    comptime if CompilationTarget.is_windows():
        assert_true(is_reserved("a<b"))
        assert_true(is_reserved("a>b"))
        assert_true(is_reserved('a"b'))
        assert_true(is_reserved("a|b"))
        assert_true(is_reserved("a*b"))
        assert_true(is_reserved("a?b"))
        assert_true(is_reserved("a\tb"))

        # A colon after the drive opens a data stream rather than naming a
        # file, which is why it is not a character a name can contain.
        assert_true(is_reserved("C:\\dir\\file.txt:stream"))

        # The drive's own colon is not that colon. It comes off before any of
        # this, which is the reason the drive is split off first.
        assert_false(is_reserved("C:\\dir\\file.txt"))
        assert_false(is_reserved("C:file.txt"))
        assert_false(is_reserved("\\\\server\\share\\file.txt"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
