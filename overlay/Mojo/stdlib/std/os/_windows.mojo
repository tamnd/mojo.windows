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
"""Asking Windows about a file, in the shape the rest of the library expects.

`stat` is one of the load bearing calls in this library even though almost
nobody calls it directly. `exists`, `isdir`, `isfile`, `makedirs` and
`Path.exists` all go through it, and opening a file for writing calls
`makedirs`, so a program that never mentions `stat` still needs it to link.

The CRT has `_wstat64`, which is the same idea with a different struct, and
that struct is the part to be careful about. `_dev_t` is thirty two bits,
`_ino_t` is sixteen, and `st_nlink`, `st_uid` and `st_gid` are all `short`, so
the padding does not fall where it falls on Linux or macOS. The layout below
was measured against the real headers rather than read off a documentation
page, and the padding is written out as named fields so that nothing depends on
what a compiler chooses to insert. `_assert_layouts` checks the totals.

Four fields come back as zero because Windows does not have the idea behind
them: `st_ino`, `st_uid`, `st_gid` and `st_blocks`. `st_blksize` is zero too,
because the cluster size is a property of the volume rather than of the file
and getting it needs a different call for a number nothing here reads.

The timestamps are a whole number of seconds, where the other platforms carry a
timespec with nanoseconds in it, so the nanosecond field is always zero on the
`stat` path. That is a real loss of resolution and not a bug in the port.
`st_ctime` is also not what it is called: on Windows it is the creation time
rather than the time of last status change, so it is reported as both
`st_ctimespec` and `st_birthtimespec`, which is the honest answer given that
Windows has a creation time and no status change time at all.

`lstat` is the interesting one, because the CRT does not have it and cannot be
made to. See `_lstat` below.
"""

from std.collections import Array
from std.ffi import external_call
from std.stat.stat import S_IFLNK
from std.sys import align_of, size_of
from std.sys._win import to_utf16
from std.time.time import (
    _CTimeSpec,
    _FILETIME_TICKS_PER_NSEC,
    _FILETIME_TICKS_TO_UNIX_EPOCH,
)

from .fstat import stat_result

# ===-----------------------------------------------------------------------===#
# Win32 constants
# ===-----------------------------------------------------------------------===#

comptime _INVALID_FILE_ATTRIBUTES = UInt32(0xFFFF_FFFF)
comptime _FILE_ATTRIBUTE_REPARSE_POINT = UInt32(0x400)

# The level argument to GetFileAttributesExW. There has only ever been one
# level and the enum exists so that there could be more.
comptime _GET_FILE_EX_INFO_STANDARD = Int32(0)

# A reparse point is not the same thing as a symlink and the difference matters
# on a real machine. Deduplication, OneDrive placeholders and a handful of
# filter drivers all set the reparse bit on ordinary files, and calling those
# symlinks would make `isfile` answer no for most of somebody's documents
# folder. Only these two tags are links in the sense POSIX means: a symlink and
# a directory junction.
comptime _IO_REPARSE_TAG_SYMLINK = UInt32(0xA000_000C)
comptime _IO_REPARSE_TAG_MOUNT_POINT = UInt32(0xA000_0003)

comptime _INVALID_HANDLE_VALUE = -1

# The two length limits inside WIN32_FIND_DATAW, which are part of the struct
# and not a choice this file gets to make.
comptime _MAX_PATH = 260
comptime _ALTERNATE_NAME_CHARS = 14

# A symlink has no permission bits of its own on any platform, so POSIX reports
# them all set and every caller has learned to ignore them.
comptime _LINK_PERMISSIONS = 0o777

# Derived rather than written out, so that there is one place holding the fact
# that a FILETIME tick is a hundred nanoseconds.
comptime _FILETIME_TICKS_PER_SEC = 1_000_000_000 // _FILETIME_TICKS_PER_NSEC


# ===-----------------------------------------------------------------------===#
# struct _stat64
# ===-----------------------------------------------------------------------===#


@fieldwise_init
struct _c_stat(Copyable, Defaultable, Writable):
    var st_dev: UInt32
    """Drive number of the disk containing the file."""
    var st_ino: UInt16
    """Always zero. Windows has no inode number to put here."""
    var st_mode: UInt16
    """File type and permission bits."""
    var st_nlink: Int16
    """Number of hard links. Always one, even when there are more."""
    var st_uid: Int16
    """Always zero. Windows does not have user ids."""
    var st_gid: Int16
    """Always zero. Windows does not have group ids."""
    var _pad0: UInt16
    """Padding, named so that it is not left to the compiler."""
    var st_rdev: UInt32
    """Drive number again, for a character device."""
    var _pad1: UInt32
    """Padding, named so that it is not left to the compiler."""
    var st_size: Int64
    """File size, in bytes."""
    var st_atime: Int64
    """Time of last access, in seconds since the Unix epoch."""
    var st_mtime: Int64
    """Time of last modification, in seconds since the Unix epoch."""
    var st_ctime: Int64
    """Time of creation, in seconds since the Unix epoch. Not the POSIX ctime.
    """

    def __init__(out self):
        self.st_dev = 0
        self.st_ino = 0
        self.st_mode = 0
        self.st_nlink = 0
        self.st_uid = 0
        self.st_gid = 0
        self._pad0 = 0
        self.st_rdev = 0
        self._pad1 = 0
        self.st_size = 0
        self.st_atime = 0
        self.st_mtime = 0
        self.st_ctime = 0

    def write_to(self, mut writer: Some[Writer]):
        # fmt: off
        writer.write(
            "{\nst_dev: ", self.st_dev,
            ",\nst_ino: ", self.st_ino,
            ",\nst_mode: ", self.st_mode,
            ",\nst_nlink: ", self.st_nlink,
            ",\nst_uid: ", self.st_uid,
            ",\nst_gid: ", self.st_gid,
            ",\nst_rdev: ", self.st_rdev,
            ",\nst_size: ", self.st_size,
            ",\nst_atime: ", self.st_atime,
            ",\nst_mtime: ", self.st_mtime,
            ",\nst_ctime: ", self.st_ctime,
            "\n}",
        )
        # fmt: on

    def _to_stat_result(self) -> stat_result:
        var creation = _CTimeSpec(Int(self.st_ctime), 0)
        return stat_result(
            st_mode=Int(self.st_mode),
            st_ino=Int(self.st_ino),
            st_dev=Int(self.st_dev),
            st_nlink=Int(self.st_nlink),
            st_uid=Int(self.st_uid),
            st_gid=Int(self.st_gid),
            st_size=Int(self.st_size),
            st_atimespec=_CTimeSpec(Int(self.st_atime), 0),
            st_mtimespec=_CTimeSpec(Int(self.st_mtime), 0),
            # The same value twice, because the Windows st_ctime is the
            # creation time and there is no status change time to report.
            st_ctimespec=creation,
            st_birthtimespec=creation,
            st_blocks=0,
            st_blksize=0,
            st_rdev=Int(self.st_rdev),
            st_flags=0,
        )


# ===-----------------------------------------------------------------------===#
# Win32 structs
# ===-----------------------------------------------------------------------===#


@fieldwise_init
struct _win32_file_attribute_data(Copyable, Defaultable):
    """What GetFileAttributesExW fills in.

    A FILETIME is two thirty two bit halves and is only four byte aligned, so
    the timestamps here are pairs of `UInt32` rather than a `UInt64`. Writing
    them as a `UInt64` would push the struct to eight byte alignment and move
    every field after the first one.
    """

    var attributes: UInt32
    """The FILE_ATTRIBUTE bits."""
    var creation: Array[UInt32, 2]
    """Creation time, low half first."""
    var last_access: Array[UInt32, 2]
    """Time of last access, low half first."""
    var last_write: Array[UInt32, 2]
    """Time of last write, low half first."""
    var size_high: UInt32
    """High thirty two bits of the size."""
    var size_low: UInt32
    """Low thirty two bits of the size."""

    def __init__(out self):
        self.attributes = 0
        self.creation = Array[UInt32, 2](fill=0)
        self.last_access = Array[UInt32, 2](fill=0)
        self.last_write = Array[UInt32, 2](fill=0)
        self.size_high = 0
        self.size_low = 0


@fieldwise_init
struct _win32_find_data(Copyable, Defaultable):
    """What FindFirstFileW fills in.

    Only `reserved0` is read, because on a reparse point it holds the reparse
    tag and that is the one thing GetFileAttributesExW will not tell you. The
    rest of the struct is here because the call writes all of it and a short
    buffer is a stack overwrite.
    """

    var attributes: UInt32
    """The FILE_ATTRIBUTE bits."""
    var creation: Array[UInt32, 2]
    """Creation time, low half first."""
    var last_access: Array[UInt32, 2]
    """Time of last access, low half first."""
    var last_write: Array[UInt32, 2]
    """Time of last write, low half first."""
    var size_high: UInt32
    """High thirty two bits of the size."""
    var size_low: UInt32
    """Low thirty two bits of the size."""
    var reserved0: UInt32
    """The reparse tag, when the reparse attribute is set."""
    var reserved1: UInt32
    """Reserved and undocumented."""
    var file_name: Array[UInt16, _MAX_PATH]
    """The name that matched, as UTF-16."""
    var alternate_name: Array[UInt16, _ALTERNATE_NAME_CHARS]
    """The old eight dot three name, when there is one."""

    def __init__(out self):
        self.attributes = 0
        self.creation = Array[UInt32, 2](fill=0)
        self.last_access = Array[UInt32, 2](fill=0)
        self.last_write = Array[UInt32, 2](fill=0)
        self.size_high = 0
        self.size_low = 0
        self.reserved0 = 0
        self.reserved1 = 0
        # Not zeroed. FindFirstFileW writes the whole name and nothing here
        # reads it, so five hundred bytes of stores would buy nothing.
        self.file_name = Array[UInt16, _MAX_PATH](uninitialized=True)
        self.alternate_name = Array[UInt16, _ALTERNATE_NAME_CHARS](
            uninitialized=True
        )


@always_inline
def _assert_layouts():
    """The measured sizes, checked rather than trusted.

    Every field above sits at its natural alignment given the fields before it,
    so a matching total size is enough to pin the whole layout down. If one of
    these fires, the struct has drifted from the header and every call in this
    file is reading the wrong bytes.
    """
    comptime assert size_of[_c_stat]() == 56, "struct _stat64 is 56 bytes"
    comptime assert align_of[_c_stat]() == 8, "struct _stat64 aligns to 8"
    comptime assert (
        size_of[_win32_file_attribute_data]() == 36
    ), "WIN32_FILE_ATTRIBUTE_DATA is 36 bytes"
    comptime assert (
        align_of[_win32_file_attribute_data]() == 4
    ), "WIN32_FILE_ATTRIBUTE_DATA aligns to 4"
    comptime assert (
        size_of[_win32_find_data]() == 592
    ), "WIN32_FIND_DATAW is 592 bytes"
    comptime assert (
        align_of[_win32_find_data]() == 4
    ), "WIN32_FIND_DATAW aligns to 4"


# ===-----------------------------------------------------------------------===#
# stat
# ===-----------------------------------------------------------------------===#


@always_inline
def _stat(var path: String) raises -> _c_stat:
    _assert_layouts()

    var stat = _c_stat()
    var wide = to_utf16(path.as_bytes())
    var err = external_call["_wstat64", Int32](
        wide.unsafe_ptr(), Pointer(to=stat)
    )
    # Nothing ties `wide` to the call, so say so, or the buffer can be freed
    # while the CRT is still reading the name out of it.
    _ = wide^
    if err == -1:
        raise Error("unable to stat '", path, "'")
    return stat^


# ===-----------------------------------------------------------------------===#
# lstat
# ===-----------------------------------------------------------------------===#


@always_inline
def _lstat(var path: String) raises -> _c_stat:
    """Like `_stat`, but does not follow a link.

    There is no `lstat` in the CRT and no flag that turns `_wstat64` into one,
    so this is assembled out of Win32 calls. The alternative was to make
    `lstat` an alias for `stat`, which would have been half a page shorter and
    would have made `islink` answer no for every link on the system. That is
    the kind of difference that goes unnoticed until somebody is deleting a
    directory tree and follows a link out of it.

    What this does get right is the thing `lstat` exists for: whether the name
    refers to a link, and the answer for a link whose target has been deleted,
    which `_wstat64` cannot report at all because it fails on it.

    What it does not get right is the size. POSIX reports the length of the
    target string and Windows reports zero for a link, and there is no way to
    the first number without opening the reparse point and parsing its buffer.
    Nothing in this library reads the size of a link, so that is where the line
    is drawn.
    """
    _assert_layouts()

    var wide = to_utf16(path.as_bytes())
    var data = _win32_file_attribute_data()
    var ok = external_call["GetFileAttributesExW", Int32](
        wide.unsafe_ptr(), _GET_FILE_EX_INFO_STANDARD, Pointer(to=data)
    )

    var is_link = False
    if ok != 0 and (data.attributes & _FILE_ATTRIBUTE_REPARSE_POINT) != 0:
        var tag = _reparse_tag(wide)
        is_link = (
            tag == _IO_REPARSE_TAG_SYMLINK
            or tag == _IO_REPARSE_TAG_MOUNT_POINT
        )
    _ = wide^

    if not is_link:
        # Either an ordinary name, or a reparse point of a kind that is not a
        # link, or a name GetFileAttributesExW could not read. In all three
        # cases the CRT gives a better answer than this file can, including a
        # better error, so let it fail if it is going to.
        return _stat(path^)

    var stat = _c_stat()
    stat.st_mode = UInt16(S_IFLNK | _LINK_PERMISSIONS)
    stat.st_nlink = 1
    # Zero, and see the note above about why.
    stat.st_size = 0
    stat.st_atime = _filetime_seconds(data.last_access)
    stat.st_mtime = _filetime_seconds(data.last_write)
    stat.st_ctime = _filetime_seconds(data.creation)
    return stat^


def _reparse_tag(wide: List[UInt16]) -> UInt32:
    """The reparse tag of a name already known to be a reparse point.

    FindFirstFileW is the cheap way to this number: it puts the tag in
    `dwReserved0` and does not follow the link to get it. Zero when it cannot
    be read, which is not a valid tag, so a caller comparing against the two
    tags that matter gets the safe answer without a separate failure path.
    """
    var found = _win32_find_data()
    var handle = external_call["FindFirstFileW", Int](
        wide.unsafe_ptr(), Pointer(to=found)
    )
    if handle == _INVALID_HANDLE_VALUE:
        # A drive root is the usual way to get here, because FindFirstFileW
        # cannot enumerate one, and a drive root is not a link.
        return 0
    _ = external_call["FindClose", Int32](handle)
    return found.reserved0


def _filetime_seconds(time: Array[UInt32, 2]) -> Int64:
    """A FILETIME, as seconds since the Unix epoch.

    The halves arrive separately because a FILETIME is only four byte aligned.
    Anything before 1970 comes back negative, which is what POSIX does with the
    same dates and is better than clamping to zero and claiming the file was
    made on the day the epoch started.
    """
    # Straight to seconds and not through nanoseconds, because a tick count of
    # zero is eleven and a half billion seconds before the epoch and that many
    # nanoseconds does not fit in a signed sixty four bit number. A zeroed
    # FILETIME is not a real timestamp, but it is what a failed call leaves
    # behind, and overflowing on it would turn a missing answer into a wrong
    # one.
    var ticks = Int64(time[0]) | (Int64(time[1]) << 32)
    return (ticks - _FILETIME_TICKS_TO_UNIX_EPOCH) // _FILETIME_TICKS_PER_SEC
