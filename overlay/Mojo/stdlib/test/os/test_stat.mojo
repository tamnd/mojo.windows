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

from std.collections import Array
from std.os import lstat, mkdir, remove, rmdir, stat
from std.os._windows import _filetime_seconds
from std.pathlib import Path
from std.stat import S_IFMT, S_IFREG, S_ISDIR, S_ISLNK, S_ISREG
from std.sys import CompilationTarget

from std.reflection import source_location
from std.testing import (
    TestSuite,
    assert_equal,
    assert_not_equal,
    assert_raises,
    assert_true,
)
from std.python import Python


def test_stat() raises:
    # A file this test makes, rather than its own source. The source is not
    # next to the binary when the test runs on a machine other than the one it
    # was built on, which is how the Windows tests run.
    var file_path = Path() / "test_stat.tmp"
    with open(file_path.__fspath__(), "w"):
        pass

    var st = stat(file_path)
    assert_not_equal(String(st), "")
    assert_true(S_ISREG(st.st_mode))

    remove(file_path)


def test_stat_mtime_ns_against_python() raises:
    comptime if CompilationTarget.is_windows():
        # Two reasons, either of which would be enough. There is no Python
        # interop on Windows yet, and the C runtime's stat reports whole
        # seconds where CPython reports the nanoseconds it reads out of NTFS,
        # so the two could not agree even once there is. That resolution loss
        # is written down in `os/_windows.mojo`.
        return

    var filename = source_location().file_name()

    var st = stat(filename)

    var py_os = Python.import_module("os")
    var py_st = py_os.stat(filename.__fspath__())

    assert_equal(st.st_atimespec.as_nanoseconds(), Int(py=py_st.st_atime_ns))
    assert_equal(st.st_mtimespec.as_nanoseconds(), Int(py=py_st.st_mtime_ns))
    assert_equal(st.st_ctimespec.as_nanoseconds(), Int(py=py_st.st_ctime_ns))
    assert_equal(st.st_mtimespec.as_nanoseconds(), Int(py=py_st.st_mtime_ns))


def test_stat_regular_file_mode_is_positive() raises:
    # macOS `mode_t` is unsigned, so decoding it as signed sign-extended every
    # regular file's mode into a negative `Int` (`S_IFREG` puts the raw 16-bit
    # value above 32767), which broke the natural `S_IFMT` mask test below.
    var file_path = Path() / "test_stat_regular_file_mode.tmp"
    with open(file_path.__fspath__(), "w"):
        pass

    var st = stat(file_path)
    assert_true(st.st_mode > 0)
    assert_equal(st.st_mode & S_IFMT, S_IFREG)
    assert_true(S_ISREG(st.st_mode))

    remove(file_path)


def test_stat_reports_the_size_that_was_written() raises:
    """The size field has to be the number of bytes in the file.

    This is the assertion that catches a struct laid out wrongly, which is the
    thing most likely to be wrong about a new platform's stat. A field read at
    the wrong offset does not fail, it returns a plausible looking number, and
    the size is the only field here whose right answer is known in advance.
    """
    comptime length = 4242

    var payload = List[Byte](length=length, fill=Byte(ord("x")))
    var file_path = Path() / "test_stat_size.tmp"
    with open(file_path.__fspath__(), "w") as f:
        f.write_bytes(Span(payload))

    assert_equal(stat(file_path).st_size, length)

    remove(file_path)


def test_stat_times_are_plausible() raises:
    """The timestamps have to be somewhere near now.

    Same idea as the size test and for the same reason: a timestamp read from
    the wrong offset, or counted from the wrong epoch, lands a long way outside
    a window this wide. Windows counts from 1601 in most of its interfaces and
    the C runtime's stat is one of the few that does not, so being sure which
    one is in play is worth an assertion.
    """
    comptime start_of_2020 = 1_577_836_800
    comptime start_of_2100 = 4_102_444_800

    var file_path = Path() / "test_stat_times.tmp"
    with open(file_path.__fspath__(), "w"):
        pass

    var st = stat(file_path)
    var seconds: List[Int] = [
        st.st_atimespec.tv_sec,
        st.st_mtimespec.tv_sec,
        st.st_ctimespec.tv_sec,
    ]
    for second in seconds:
        assert_true(second > start_of_2020, "timestamp is before 2020")
        assert_true(second < start_of_2100, "timestamp is after 2100")

    remove(file_path)


def test_stat_directory() raises:
    var dir_path = Path() / "test_stat_directory.tmp"
    mkdir(dir_path)

    var st = stat(dir_path)
    assert_true(S_ISDIR(st.st_mode), "a directory did not stat as one")
    assert_true(not S_ISREG(st.st_mode), "a directory stat as a regular file")

    rmdir(dir_path)


def test_stat_missing_file_raises() raises:
    var file_path = Path() / "test_stat_missing.tmp"
    with assert_raises():
        _ = stat(file_path)


def test_lstat_on_a_regular_file() raises:
    """A file that is not a link has to look the same through both calls.

    Not much of a test on Linux or macOS, where `lstat` is one call away from
    `stat`. It is worth having for Windows, where there is no `lstat` in the C
    runtime and the one in this library is assembled out of Win32 calls, so the
    ordinary case genuinely can come back different.
    """
    var file_path = Path() / "test_lstat.tmp"
    with open(file_path.__fspath__(), "w") as f:
        f.write("hello")

    var st = stat(file_path)
    var lst = lstat(file_path)

    assert_true(S_ISREG(lst.st_mode), "a regular file did not lstat as one")
    assert_true(not S_ISLNK(lst.st_mode), "a regular file lstat as a link")
    assert_equal(lst.st_mode, st.st_mode)
    assert_equal(lst.st_size, st.st_size)
    assert_equal(lst.st_mtimespec.tv_sec, st.st_mtimespec.tv_sec)

    remove(file_path)


def test_filetime_epoch() raises:
    """A FILETIME is a count from 1601 and has to come back as one from 1970.

    This runs everywhere, because it is arithmetic and nothing else. It is here
    because the Windows `lstat` uses it on the one path CI cannot reach, which
    is a real symbolic link: making one on Windows needs a privilege that a
    test runner does not have, so the conversion would otherwise ship with
    nothing checking it at all. Getting the offset wrong lands three and a half
    centuries out, which every one of these catches.
    """
    comptime ticks_at_epoch = 116_444_736_000_000_000
    comptime ticks_per_second = 10_000_000

    def as_halves(ticks: Int) -> Array[UInt32, 2]:
        var halves: Array[UInt32, 2] = [
            UInt32(ticks & 0xFFFF_FFFF),
            UInt32((ticks >> 32) & 0xFFFF_FFFF),
        ]
        return halves^

    assert_equal(_filetime_seconds(as_halves(ticks_at_epoch)), 0)
    assert_equal(
        _filetime_seconds(as_halves(ticks_at_epoch + ticks_per_second)), 1
    )
    # The first of January 2020, which needs both halves to be right: it is
    # well above two to the thirty two ticks and so is the epoch offset itself.
    assert_equal(
        _filetime_seconds(
            as_halves(ticks_at_epoch + 1_577_836_800 * ticks_per_second)
        ),
        1_577_836_800,
    )
    # A date before 1970, which POSIX reports as a negative number rather than
    # clamping, and so does this.
    assert_true(_filetime_seconds(as_halves(ticks_at_epoch - 1)) <= 0)
    assert_true(_filetime_seconds(as_halves(0)) < -11_000_000_000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
