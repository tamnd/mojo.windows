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

from std.os.path import splitroot
from std.sys.info import CompilationTarget

from std.testing import TestSuite, assert_equal


def _splitroot_test(
    path: String,
    expected_drive: String,
    expected_root: String,
    expected_tail: String,
) raises:
    var drive, root, tail = splitroot(path)
    assert_equal(drive, expected_drive)
    assert_equal(root, expected_root)
    assert_equal(tail, expected_tail)


def test_absolute_path() raises:
    comptime if CompilationTarget.is_windows():
        # A run of leading separators is a share name on Windows and a plain
        # root on Unix, so these cannot be the same cases with the separator
        # swapped. Everything with one leading separator agrees on both.
        _splitroot_test("/usr/lib/file.txt", "", "/", "usr/lib/file.txt")
        _splitroot_test("//usr/lib/file.txt", "//usr/lib", "/", "file.txt")
        _splitroot_test("///usr/lib/file.txt", "///usr", "/", "lib/file.txt")
        _splitroot_test("/a", "", "/", "a")
        _splitroot_test("\\a", "", "\\", "a")
        _splitroot_test("/a/b", "", "/", "a/b")
        _splitroot_test("/a/b/", "", "/", "a/b/")
        return

    _splitroot_test("/usr/lib/file.txt", "", "/", "usr/lib/file.txt")
    _splitroot_test("//usr/lib/file.txt", "", "//", "usr/lib/file.txt")
    _splitroot_test("///usr/lib/file.txt", "", "/", "//usr/lib/file.txt")
    _splitroot_test("/a", "", "/", "a")
    _splitroot_test("/a/b", "", "/", "a/b")
    _splitroot_test("/a/b/", "", "/", "a/b/")


def test_relative_path() raises:
    _splitroot_test("usr/lib/file.txt", "", "", "usr/lib/file.txt")
    _splitroot_test(".", "", "", ".")
    _splitroot_test("..", "", "", "..")
    _splitroot_test(
        "entire/.//.tail/..//captured////",
        "",
        "",
        "entire/.//.tail/..//captured////",
    )
    _splitroot_test("a", "", "", "a")
    _splitroot_test("a/b", "", "", "a/b")
    _splitroot_test("a/b/", "", "", "a/b/")


def test_root_directory() raises:
    comptime if CompilationTarget.is_windows():
        _splitroot_test("/", "", "/", "")
        _splitroot_test("\\", "", "\\", "")
        # Two separators and nothing after them is the start of a share name
        # that never arrived, and a share name is drive.
        _splitroot_test("//", "//", "", "")
        _splitroot_test("///", "///", "", "")
        return

    _splitroot_test("/", "", "/", "")
    _splitroot_test("//", "", "//", "")
    _splitroot_test("///", "", "/", "//")


def test_empty_path() raises:
    _splitroot_test("", "", "", "")


# A drive letter with a root after it and one without are different paths.
def test_windows_drive_letter() raises:
    comptime if CompilationTarget.is_windows():
        # `C:` names a drive and nothing on it, so there is no root and no
        # tail.
        _splitroot_test("C:", "C:", "", "")

        # `C:\` is the top of that drive.
        _splitroot_test("C:\\", "C:", "\\", "")
        _splitroot_test("C:/", "C:", "/", "")

        # `C:Users` is relative to wherever this process last was on C, which
        # is why the root comes back empty and the drive does not.
        _splitroot_test("C:Users\\name", "C:", "", "Users\\name")
        _splitroot_test("C:\\Users\\name", "C:", "\\", "Users\\name")
        _splitroot_test("c:/Users/name", "c:", "/", "Users/name")

        # Only the first separator is the root. The rest is tail, odd as that
        # looks.
        _splitroot_test("C:///spam///ham", "C:", "/", "//spam///ham")


# The server and the share together are the drive, and neither half alone is.
def test_windows_unc_and_device() raises:
    comptime if CompilationTarget.is_windows():
        _splitroot_test(
            "\\\\server\\share\\dir", "\\\\server\\share", "\\", "dir"
        )
        _splitroot_test("//server/share/dir", "//server/share", "/", "dir")

        # A share with nothing under it, and a server with no share. Neither is
        # a place a process can be, so both are all drive.
        _splitroot_test("\\\\server\\share", "\\\\server\\share", "", "")
        _splitroot_test("\\\\server", "\\\\server", "", "")

        # `\\?\` turns off path parsing in the kernel. The two components after
        # it are still the drive, so `\\?\C:` is one of them and `Users` is the
        # tail.
        _splitroot_test("\\\\?\\C:\\Users", "\\\\?\\C:", "\\", "Users")

        # `\\?\UNC\` is the same trick applied to a share, and it puts the
        # server name eight bytes in rather than two.
        _splitroot_test(
            "\\\\?\\UNC\\server\\share\\dir",
            "\\\\?\\UNC\\server\\share",
            "\\",
            "dir",
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
