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

from std.os.path import join
from std.pathlib import Path
from std.sys.info import CompilationTarget

from std.testing import TestSuite, assert_equal


def test_join() raises:
    comptime if CompilationTarget.is_windows():
        # A backslash goes in between, but whatever separators the caller
        # already wrote are left as they are. That is why some of these come
        # back with both kinds in one string.
        assert_equal("path\\to\\file", join("path", "to", "file"))
        assert_equal("path\\to/file", join("path", "to/file"))
        assert_equal("path/to\\file", join("path/to", "file"))
        assert_equal("path/to/file", join("path/", "to/", "file"))

        assert_equal("a\\b\\c", join("a", "b\\", "c"))
        assert_equal("a\\b\\c", join("a", "b", "", "c"))

        assert_equal("path\\", join("path", ""))
        assert_equal("path", join("path"))
        assert_equal("", join(""))
        assert_equal("path", join("", "path"))

        assert_equal("\\path\\to\\file", join("ignored", "\\path\\to", "file"))
        return

    # TODO uncomment lines using Path when unpacking is supported
    assert_equal("path/to/file", join("path", "to", "file"))
    # assert_equal("path/to/file", join(Path("path"), Path("to"), Path("file")))
    assert_equal("path/to/file", join("path", "to/file"))
    # assert_equal("path/to/file", join(Path("path"), Path("to/file")))
    assert_equal("path/to/file", join("path/to", "file"))
    # assert_equal("path/to/file", join(Path("path/to"), Path("file")))
    assert_equal("path/to/file", join("path/", "to/", "file"))

    assert_equal("/a/b", join("/", "a", "b"))
    assert_equal("a/b/c", join("a", "b/", "c"))
    assert_equal("a/b/c", join("a", "b", "", "c"))

    assert_equal("path/", join("path", ""))
    # assert_equal("path/", join(Path("path"), Path("")))
    assert_equal("path", join("path"))
    # assert_equal("path", join(Path("path")))
    assert_equal("", join(""))
    assert_equal("path", join("", "path"))

    assert_equal("/path/to/file", join("ignored", "/path/to", "file"))
    # assert_equal("/path/to/file", join(Path("ignored"), Path("/path/to/file")))
    assert_equal(
        "/absolute/path",
        join("ignored", "/ignored/absolute/path", "/absolute", "path"),
    )
    # assert_equal(
    #     "/path/to/file",
    #     join(
    #         Path("ignored"),
    #         Path("/path/to/file/but/ignored/again"),
    #         Path("/path/to/file"),
    #     ),
    # )


# What a drive letter on the right hand side does to the left hand side.
def test_join_windows_drive() raises:
    comptime if CompilationTarget.is_windows():
        assert_equal("C:\\a\\b", join("C:\\", "a", "b"))

        # A root on the right replaces the path but keeps the drive, so this
        # stays on C rather than landing on whichever drive is current.
        assert_equal("C:\\b", join("C:\\a", "\\b"))

        # A different drive says nothing about a place on this one, so the left
        # hand side is dropped entirely.
        assert_equal("D:\\b", join("C:\\a", "D:\\b"))
        assert_equal("d:b", join("C:\\a", "d:b"))

        # The same drive in a different case is still the same drive. The
        # spelling the caller just wrote wins.
        assert_equal("c:\\a\\b", join("C:\\a", "c:b"))

        # `C:a` is a real path and is not `C:\a`, so nothing is inserted here.
        assert_equal("C:a", join("C:", "a"))


# A share is a drive with no root, so a separator has to go back in after it.
def test_join_windows_unc() raises:
    comptime if CompilationTarget.is_windows():
        assert_equal("\\\\server\\share\\dir", join("\\\\server\\share", "dir"))
        assert_equal(
            "\\\\server\\share\\dir", join("\\\\server\\share\\", "dir")
        )
        assert_equal(
            "\\\\server\\share\\dir", join("\\\\server\\share", "\\dir")
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
