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

Listing a directory is here too, for the same reason: `opendir` and `readdir`
are not in the CRT either, and the Win32 way of walking a directory hands back
the same `WIN32_FIND_DATAW` that `_lstat` already needed. See `_listdir`.

Hard links, symbolic links and real paths are here as well. `link`, `symlink`
and `realpath` are not in the CRT under any spelling, and all three have a Win32
equivalent that takes its arguments in the other order or answers a slightly
different question. See the middle section.

Making and removing a directory and deleting a file are the odd ones out,
because the CRT does have all three and using them is still wrong. Its `mkdir`,
`rmdir` and `unlink` take a narrow string, so a name with anything outside the
current code page in it does not survive the trip, and a path they are given is
subject to the classic length limit with no way to say otherwise. Both of those
go away by calling Win32 with a wide string, which is what everything else in
this file already does. See the last section.
"""

from std.collections import Array
from std.ffi import external_call
from std.sys._libc_errno import errno_from_win32, get_errno, set_errno
from std.stat.stat import S_IFDIR, S_IFLNK, S_IFREG
from std.sys import align_of, size_of
from std.sys._win import (
    close_handle,
    error_message,
    final_path,
    last_error,
    to_utf16,
    to_utf8,
    wide_len,
)
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

comptime _FILE_ATTRIBUTE_DIRECTORY = UInt32(0x10)
comptime _FILE_ATTRIBUTE_READONLY = UInt32(0x1)

# The permission bits a file gets when Win32 is asked instead of the C runtime.
# Windows has no such bits and `_wstat64` makes them up out of one attribute and
# the extension, so there is a right answer here and it is whatever that
# function does. See `_stat_by_handle`.
comptime _STAT_READ = 0o444
comptime _STAT_WRITE = 0o222
comptime _STAT_EXECUTE = 0o111

# How FindNextFileW says the enumeration is over. It reports that by failing,
# so every walk of a directory ends in an error that is not one, and the only
# way to tell it apart from a real failure is to look at the code.
comptime _ERROR_NO_MORE_FILES = UInt32(18)

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

# What CreateFileW needs to open a name only in order to ask about it.
# FILE_READ_ATTRIBUTES is enough for GetFileInformationByHandle and for
# GetFinalPathNameByHandleW, and it is the access a file somebody else has open
# for writing will still grant. All three share bits are set for the same
# reason: the default is to share nothing, which would make asking about a busy
# file fail for a reason that has nothing to do with the question.
comptime _FILE_READ_ATTRIBUTES = UInt32(0x80)
comptime _FILE_SHARE_ALL = UInt32(0x7)
comptime _OPEN_EXISTING = UInt32(3)

# Without this CreateFileW cannot open a directory at all, which is the most
# surprising thing about it. The name is about backup programs and the flag is
# about nothing else.
comptime _FILE_FLAG_BACKUP_SEMANTICS = UInt32(0x0200_0000)

# CreateSymbolicLinkW says up front whether the target is a directory, because
# it has to create the reparse point before anything resolves it.
comptime _SYMBOLIC_LINK_FLAG_DIRECTORY = UInt32(0x1)

# Creating a symlink is a privileged operation unless the machine is in
# Developer Mode, and this flag is how a caller says it is willing to rely on
# that. Older builds reject the flag itself rather than ignoring it, which is
# what the retry in `_symlink` is for.
comptime _SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = UInt32(0x2)

comptime _ERROR_INVALID_PARAMETER = UInt32(87)
comptime _ERROR_PRIVILEGE_NOT_HELD = UInt32(1314)


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

    Three fields are read and the rest are here because the call writes all of
    them and a short buffer is a stack overwrite. `reserved0` holds the reparse
    tag on a reparse point, which is the one thing GetFileAttributesExW will
    not tell you. `file_name` and `attributes` are what listing a directory is
    for.
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
        # Not zeroed. FindFirstFileW writes the name and a nul after it on
        # every successful call, and nothing reads the buffer after a failed
        # one, so five hundred bytes of stores would buy nothing.
        self.file_name = Array[UInt16, _MAX_PATH](uninitialized=True)
        self.alternate_name = Array[UInt16, _ALTERNATE_NAME_CHARS](
            uninitialized=True
        )


@fieldwise_init
struct _by_handle_file_information(Copyable, Defaultable):
    """What GetFileInformationByHandle fills in.

    Two of these fields are the reason this call is worth opening a handle for.
    `links` is the hard link count, which the CRT's `stat` reports as one no
    matter how many there are, and the two halves of the file index are the
    closest thing Windows has to an inode number. Everything else in here is
    also in WIN32_FILE_ATTRIBUTE_DATA and is not read.

    The FILETIME fields are pairs of `UInt32` for the same reason they are in
    `_win32_file_attribute_data`: a FILETIME is only four byte aligned and
    writing one as a `UInt64` would move every field after it.
    """

    var attributes: UInt32
    """The FILE_ATTRIBUTE bits."""
    var creation: Array[UInt32, 2]
    """Creation time, low half first."""
    var last_access: Array[UInt32, 2]
    """Time of last access, low half first."""
    var last_write: Array[UInt32, 2]
    """Time of last write, low half first."""
    var volume_serial: UInt32
    """Serial number of the volume the file is on."""
    var size_high: UInt32
    """High thirty two bits of the size."""
    var size_low: UInt32
    """Low thirty two bits of the size."""
    var links: UInt32
    """Number of hard links to the file."""
    var index_high: UInt32
    """High thirty two bits of the file index."""
    var index_low: UInt32
    """Low thirty two bits of the file index."""

    def __init__(out self):
        self.attributes = 0
        self.creation = Array[UInt32, 2](fill=0)
        self.last_access = Array[UInt32, 2](fill=0)
        self.last_write = Array[UInt32, 2](fill=0)
        self.volume_serial = 0
        self.size_high = 0
        self.size_low = 0
        self.links = 0
        self.index_high = 0
        self.index_low = 0


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
    comptime assert (
        size_of[_by_handle_file_information]() == 52
    ), "BY_HANDLE_FILE_INFORMATION is 52 bytes"
    comptime assert (
        align_of[_by_handle_file_information]() == 4
    ), "BY_HANDLE_FILE_INFORMATION aligns to 4"


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
    if err == -1:
        # The C runtime parses the name itself before it calls anything, and
        # that parsing still has the classic length limit in it and does not
        # know what the extended prefix means. So a path long enough for
        # `to_utf16` to have prefixed it fails here whether or not the file is
        # there, and asking Win32 is the only way to tell those two apart.
        var by_handle = _stat_by_handle(wide, path)
        # Nothing ties `wide` to either call, so say so, or the buffer can be
        # freed while one of them is still reading the name out of it.
        _ = wide^
        return by_handle^

    _ = wide^
    return stat^


def _is_executable_name(path: StringSlice) -> Bool:
    """Whether the name ends in one of the extensions Windows will run.

    The C runtime sets the execute bits from the extension because there is
    nothing else on this platform to set them from, and the list is fixed rather
    than read out of PATHEXT. Matching it matters here because the two ways of
    answering `stat` have to agree about the same file.
    """
    var lowered = String(path).lower()
    return (
        lowered.endswith(".exe")
        or lowered.endswith(".cmd")
        or lowered.endswith(".bat")
        or lowered.endswith(".com")
    )


def _stat_by_handle(wide: List[UInt16], path: StringSlice) raises -> _c_stat:
    """`stat` without the C runtime, for a name the C runtime cannot see.

    Opening the file is what makes this follow a link the way `stat` is supposed
    to. GetFileAttributesExW would answer the same questions without a handle
    and would answer them about the link rather than about what it points at,
    which is `lstat` and not this.

    Two fields are deliberately the same lie the C runtime tells. `st_nlink` is
    one, and `st_dev` is zero rather than the drive number, because a caller
    that wants either of those really wants `os.stat`, which fills both in from
    a handle of its own and would otherwise get a different answer depending on
    how long the path was.
    """
    _assert_layouts()

    var handle = _open_for_query(wide)
    if handle == _INVALID_HANDLE_VALUE:
        raise Error("unable to stat '", path, "'")

    var info = _by_handle_file_information()
    var ok = external_call["GetFileInformationByHandle", Int32](
        handle, Pointer(to=info)
    )
    close_handle(handle)
    if ok == 0:
        raise Error("unable to stat '", path, "'")

    var directory = (info.attributes & _FILE_ATTRIBUTE_DIRECTORY) != 0
    var mode = S_IFDIR | _STAT_EXECUTE if directory else S_IFREG
    mode |= _STAT_READ
    if (info.attributes & _FILE_ATTRIBUTE_READONLY) == 0:
        mode |= _STAT_WRITE
    if not directory and _is_executable_name(path):
        mode |= _STAT_EXECUTE

    var stat = _c_stat()
    stat.st_mode = UInt16(mode)
    stat.st_nlink = 1
    stat.st_size = Int64(
        (UInt64(info.size_high) << 32) | UInt64(info.size_low)
    )
    stat.st_atime = _filetime_seconds(info.last_access)
    stat.st_mtime = _filetime_seconds(info.last_write)
    stat.st_ctime = _filetime_seconds(info.creation)
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


# ===-----------------------------------------------------------------------===#
# listdir
# ===-----------------------------------------------------------------------===#


@fieldwise_init
struct _dir_entry(Copyable, Movable):
    """One name out of a directory, with what the enumeration already knew.

    The attributes come free. Windows hands them back with the name, where
    POSIX gives a name and makes the caller pay for a `stat` to learn anything
    else, which is why `_rmtree` asks `isfile` and then `isdir` about every
    entry it walks. Nothing reads `attributes` yet and the answer to that is a
    change to the public `listdir`, which returns names. Throwing the field
    away here would make that change start by rewriting this file.
    """

    var name: String
    """The entry's name, with no directory in front of it."""
    var attributes: UInt32
    """The FILE_ATTRIBUTE bits, as the enumeration reported them."""


def _search_pattern(path: String) -> String:
    """The directory, with the wildcard on the end that Win32 wants.

    FindFirstFileW takes a pattern and not a directory, so listing one means
    asking it for everything in it. The separator only goes on when there is
    not one there already, and a bare drive letter counts as one, because
    `C:*` asks about the current directory on C and `C:\\*` asks about its
    root, and those are different places.
    """
    var pattern = path.copy()
    if not pattern:
        # An empty path is the current directory, which is what the POSIX side
        # would answer for it too, by way of `opendir("")` failing and nobody
        # calling it that way.
        return String("*")

    comptime backslash = Byte(ord("\\"))
    comptime slash = Byte(ord("/"))
    comptime colon = Byte(ord(":"))
    var last = pattern.as_bytes()[pattern.byte_length() - 1]
    if last == backslash or last == slash or last == colon:
        pattern += "*"
    else:
        pattern += "\\*"
    return pattern^


def _entry_name(ref found: _win32_find_data) -> String:
    """The name out of a filled in WIN32_FIND_DATAW, as UTF-8."""
    var buffer = Span(
        unsafe_ptr=found.file_name.unsafe_ptr(), length=Int(_MAX_PATH)
    )
    return to_utf8(buffer[: wide_len(buffer)])


def _listdir(var path: String) raises -> List[_dir_entry]:
    """Everything in a directory except the two entries that are not in it.

    `.` and `..` are dropped by name rather than by position. They come first
    on the filesystems anybody is likely to be using, and the documentation
    does not promise it, and a network redirector is allowed to leave them out
    entirely. Comparing the name costs nothing next to the call that produced
    it.

    The path goes in as it arrived, which means the usual limit of 260
    characters applies to it. Getting past that needs the `\\\\?\\` prefix,
    which is a decision about every path in this library rather than about this
    one call. See the long path issue for that.
    """
    _assert_layouts()

    var found = _win32_find_data()
    var wide = to_utf16(_search_pattern(path).as_bytes())
    var handle = external_call["FindFirstFileW", Int](
        wide.unsafe_ptr(), Pointer(to=found)
    )
    # Nothing ties `wide` to the call, so say so, or the buffer can be freed
    # while Windows is still reading the pattern out of it.
    _ = wide^

    if handle == _INVALID_HANDLE_VALUE:
        # No check that the path is a directory before this, because the system
        # has already made it and says so better. A file gets "The directory
        # name is invalid" and a missing name gets "The system cannot find the
        # path specified", which are two different problems that one check of
        # our own would have flattened into one message.
        raise Error(
            "unable to list the directory '",
            path,
            "': ",
            error_message(last_error()),
        )

    var entries = List[_dir_entry]()
    while True:
        var name = _entry_name(found)
        if name != "." and name != "..":
            entries.append(_dir_entry(name^, found.attributes))
        if (
            external_call["FindNextFileW", Int32](handle, Pointer(to=found))
            == 0
        ):
            break

    # Read before the close, because closing a handle sets the thread's error
    # code and would answer a question about itself rather than about the walk.
    var code = last_error()
    _ = external_call["FindClose", Int32](handle)
    if code != _ERROR_NO_MORE_FILES:
        raise Error(
            "unable to finish listing the directory '",
            path,
            "': ",
            error_message(code),
        )

    return entries^


# ===-----------------------------------------------------------------------===#
# Handles
# ===-----------------------------------------------------------------------===#


def _open_for_query(wide: List[UInt16]) -> Int:
    """A handle good only for asking about a name, or the invalid handle.

    Everything below that needs more than a name needs one of these and they all
    want it opened the same way. See the constants above for what each argument
    is doing, in particular the backup semantics flag, which is the difference
    between this working on a directory and refusing to.
    """
    return external_call["CreateFileW", Int](
        wide.unsafe_ptr(),
        _FILE_READ_ATTRIBUTES,
        _FILE_SHARE_ALL,
        # No security attributes, which is what anything that is not creating
        # something passes.
        OptionalPointer[NoneType, MutUntrackedOrigin](),
        _OPEN_EXISTING,
        _FILE_FLAG_BACKUP_SEMANTICS,
        # No template file, which is also only meaningful when creating.
        Int(0),
    )


# ===-----------------------------------------------------------------------===#
# stat, with the fields a handle can answer
# ===-----------------------------------------------------------------------===#


def _stat_with_identity(var path: String) raises -> stat_result:
    """`stat`, with the two fields the C runtime cannot answer filled in.

    `_wstat64` reports `st_ino` as zero and `st_nlink` as one for every file.
    That is fine for the predicates in `os.path`, which read neither, and wrong
    for the two questions anybody actually asks a `stat_result` about a hard
    link: whether two names are the same file, and how many names it has. Both
    are in BY_HANDLE_FILE_INFORMATION and both cost a handle.

    That cost is why this is not what `_stat` does. `exists`, `isdir`, `isfile`
    and `makedirs` all go through `_stat`, and opening a handle for them would
    slow down the common path to answer a question none of them ask. `os.stat`
    is the entry point where somebody is holding the whole structure.

    A name that cannot be opened keeps the C runtime's answers rather than
    failing. It has already been resolved by then, so there is a real
    `stat_result` in hand, and giving that up because of an antivirus filter or
    a file somebody has open for exclusive access would be a worse answer than
    an incomplete one.
    """
    var result = _stat(path.copy())._to_stat_result()

    var wide = to_utf16(path.as_bytes())
    var handle = _open_for_query(wide)
    _ = wide^
    if handle == _INVALID_HANDLE_VALUE:
        return result^

    var info = _by_handle_file_information()
    var ok = external_call["GetFileInformationByHandle", Int32](
        handle, Pointer(to=info)
    )
    close_handle(handle)
    if ok == 0:
        return result^

    # Signed, and a file index is allowed to use all sixty four bits, so this
    # can come out negative. Nothing does arithmetic on an inode number. It is
    # compared against another one, and a wrapped value compares the same way
    # the unwrapped one would.
    result.st_ino = Int(
        (UInt64(info.index_high) << 32) | UInt64(info.index_low)
    )
    # The volume serial comes from the same call because the two belong
    # together. POSIX says `st_ino` is unique for a given `st_dev`, and the
    # drive number the C runtime puts in `st_dev` is not what this index is
    # unique within, so taking one without the other would produce a pair that
    # does not mean anything.
    result.st_dev = Int(info.volume_serial)
    result.st_nlink = Int(info.links)
    return result^


# ===-----------------------------------------------------------------------===#
# link, symlink and realpath
# ===-----------------------------------------------------------------------===#


def _link(var oldpath: String, var newpath: String) raises:
    """A hard link, with the arguments in the order Win32 wants them.

    CreateHardLinkW names the link first and the existing file second, which is
    the other way round from `link(2)`, and both spellings read as "from, to" to
    anybody who has not just looked it up. Getting it backwards makes a link
    with the wrong name and reports no error at all, so the swap happens here
    and happens once.

    NTFS only, and one volume only. ReFS has no hard links and FAT never did, so
    a link across a drive letter or onto a USB stick fails, and the sentence the
    system gives for it is more use than a check of our own would be.
    """
    var wide_new = to_utf16(newpath.as_bytes())
    var wide_old = to_utf16(oldpath.as_bytes())
    var ok = external_call["CreateHardLinkW", Int32](
        wide_new.unsafe_ptr(),
        wide_old.unsafe_ptr(),
        # No security attributes. A hard link is another directory entry for a
        # file that already has an ACL, so there is nothing here to describe.
        OptionalPointer[NoneType, MutUntrackedOrigin](),
    )
    var code = last_error()
    _ = wide_new^
    _ = wide_old^

    if ok == 0:
        raise Error(
            "Can not create link from ",
            newpath,
            " to ",
            oldpath,
            " Err: ",
            error_message(code),
        )


def _target_is_directory(wide_target: List[UInt16]) -> Bool:
    """Whether the target is there and is a directory.

    A POSIX symlink does not care what it points at and can be made before the
    target exists. A Windows one has to say which it is at creation time,
    because the reparse point is tagged as a file link or a directory link and
    nothing re-reads the tag later. So this looks, and a target that is not
    there yet is taken to be a file, which is the common case and the one the
    standard library's own test does.
    """
    var attributes = external_call["GetFileAttributesW", UInt32](
        wide_target.unsafe_ptr()
    )
    if attributes == _INVALID_FILE_ATTRIBUTES:
        return False
    return (attributes & _FILE_ATTRIBUTE_DIRECTORY) != 0


def _symlink(var target: String, var linkpath: String) raises:
    """A symbolic link, or an error saying why the system would not make one.

    Three things are different from `symlink(2)` and all three have bitten
    somebody.

    CreateSymbolicLinkW names the link first and the target second, the other
    way round from POSIX, the same trap as `_link` above.

    Making one is privileged. An ordinary account does not hold
    SeCreateSymbolicLinkPrivilege, so this is not a missing call, it is a call
    that fails with ERROR_PRIVILEGE_NOT_HELD, and the way through it is
    Developer Mode plus a flag saying the caller is willing to rely on that.
    Builds before Windows 10 1703 reject the flag itself as an invalid
    parameter rather than ignoring it, which is what the retry is for.

    It returns BOOLEAN and not BOOL, so the answer is one byte wide. Reading
    four would pick up whatever else happened to be in the register.
    """
    var wide_link = to_utf16(linkpath.as_bytes())
    var wide_target = to_utf16(target.as_bytes())

    var flags = UInt32(0)
    if _target_is_directory(wide_target):
        flags |= _SYMBOLIC_LINK_FLAG_DIRECTORY

    var ok = external_call["CreateSymbolicLinkW", UInt8](
        wide_link.unsafe_ptr(),
        wide_target.unsafe_ptr(),
        flags | _SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE,
    )
    var code = last_error()
    if ok == 0 and code == _ERROR_INVALID_PARAMETER:
        ok = external_call["CreateSymbolicLinkW", UInt8](
            wide_link.unsafe_ptr(), wide_target.unsafe_ptr(), flags
        )
        code = last_error()

    _ = wide_link^
    _ = wide_target^

    if ok == 0:
        # The system's sentence for ERROR_PRIVILEGE_NOT_HELD is "A required
        # privilege is not held by the client", which is true and tells nobody
        # what to do about it. This is the one code worth a sentence of our own.
        var reason = error_message(code)
        if code == _ERROR_PRIVILEGE_NOT_HELD:
            reason = String(
                "the account does not hold SeCreateSymbolicLinkPrivilege and"
                " the machine is not in Developer Mode"
            )
        raise Error(
            "Can not create symlink from ",
            linkpath,
            " to ",
            target,
            " Err: ",
            reason,
        )


def _realpath(var path: String) raises -> String:
    """The canonical name of a file that exists.

    The call that answers this works from an open handle rather than from a
    name, so this opens the file, and so this fails for a name that is not
    there. POSIX `realpath` fails there too, which means the two platforms
    agree, and a caller that wants an answer for a path which does not exist
    yet wants `abspath`. `final_path` in `sys._win` is the rest of it, and is
    there rather than here because `sys._fd` needs the same thing.
    """
    var wide = to_utf16(path.as_bytes())
    var handle = _open_for_query(wide)
    _ = wide^
    if handle == _INVALID_HANDLE_VALUE:
        # POSIX `realpath` reports through errno and the message the caller
        # sees is the errno message, so this reports the same way rather than
        # handing back a Win32 sentence saying the same thing in other words.
        # `errno_from_win32` in `sys._libc_errno` is the translation.
        set_errno(errno_from_win32(last_error()))
        raise Error("realpath failed to resolve: ", get_errno())

    try:
        var resolved = final_path(handle)
        close_handle(handle)
        return resolved^
    except e:
        close_handle(handle)
        set_errno(errno_from_win32(last_error()))
        raise Error("realpath failed to resolve: ", e)


# ===-----------------------------------------------------------------------===#
# mkdir, rmdir and remove
# ===-----------------------------------------------------------------------===#


def _mkdir(var path: String) raises:
    """Creates one directory, with no mode.

    POSIX takes a mode and Windows takes a security descriptor, and the two are
    not the same idea written differently. A mode says what the owner, the group
    and everybody else may do; an ACL is a list of who may do what, with no
    group and no notion of everybody else that lines up with the POSIX one. So
    the mode is dropped rather than approximated, and the new directory
    inherits its parent's ACL, which is what a directory made by any other
    Windows program gets.
    """
    var wide = to_utf16(path.as_bytes())
    var ok = external_call["CreateDirectoryW", Int32](
        wide.unsafe_ptr(),
        # No security attributes, so the parent's ACL is inherited.
        OptionalPointer[NoneType, MutUntrackedOrigin](),
    )
    var code = last_error()
    _ = wide^

    if ok == 0:
        set_errno(errno_from_win32(code))
        raise Error(
            "Can not create directory: ", path, " Err: ", error_message(code)
        )


def _rmdir(var path: String) raises:
    """Removes one directory, which has to be empty and has to be a directory.

    RemoveDirectoryW refuses a file and refuses a directory with anything in it,
    the same two refusals `rmdir(2)` makes, so nothing here has to check for
    either. It also refuses a symlink's target: given a link to a directory it
    removes the link, which is again what POSIX does.
    """
    var wide = to_utf16(path.as_bytes())
    var ok = external_call["RemoveDirectoryW", Int32](wide.unsafe_ptr())
    var code = last_error()
    _ = wide^

    if ok == 0:
        set_errno(errno_from_win32(code))
        raise Error(
            "Can not remove directory: ", path, " Err: ", error_message(code)
        )


def _remove(var path: String) raises:
    """Deletes one file.

    The name goes as soon as this returns and the file goes when the last
    handle to it closes, which is the part that is not POSIX. On POSIX an open
    file can be unlinked and the program carries on reading it; here the delete
    fails outright unless whoever opened it asked to share deletion, and almost
    nothing does. A test that removes a file it still has open passes on Linux
    and fails here, and that is the system's answer rather than something this
    can paper over.
    """
    var wide = to_utf16(path.as_bytes())
    var ok = external_call["DeleteFileW", Int32](wide.unsafe_ptr())
    var code = last_error()
    _ = wide^

    if ok == 0:
        set_errno(errno_from_win32(code))
        raise Error(
            "Can not remove file: ", path, " Err: ", error_message(code)
        )
