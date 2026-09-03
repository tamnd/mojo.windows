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
"""File descriptors, on the two operating systems that agree on the idea and
not on the spelling.

A file descriptor is a POSIX invention: a small integer indexing a per process
table, with `open` handing them out and `read`, `write`, `lseek` and `close`
taking them. Windows does not work that way underneath, where a file is a
HANDLE, but its C runtime keeps a table of descriptors over the top of those
handles and exposes exactly those five calls. So the standard library gets to
keep the model and change only the names, which is a much better trade than
rewriting `FileHandle` around handles.

This module is where the names change. It sits above `_libc` for the same
reason `_dl` does: `_libc` is unconditional POSIX and is readable because of
it, so the conditional layer belongs on top.

Three things are not just a rename.

The first is text mode, and it is the reason to read this file before touching
anything that opens a file. Windows opens in text mode unless told otherwise,
which turns every `\\n` written into `\\r\\n` and every `\\r\\n` read into
`\\n`. That is not an error, nothing reports it, and the only way to notice is
that a file written on Windows does not match the same file written anywhere
else. So `O_BINARY` exists on every platform, zero where there is no such idea,
and the modes in `io.file` all carry it. It is defined for POSIX too so that
somebody reading the flags on Linux can see that the decision was made rather
than assume nobody thought about it.

That covers files, and not the three standard streams, which the CRT has
already opened in text mode before any code here runs, so there is no flag left
to pass. Those are switched over at startup instead, by
`_set_standard_streams_to_binary_mode` in `builtin/_startup.mojo`, which is also
where the reasoning for picking binary is written down. `fd_set_binary_mode`
below is what it calls, and is also for a descriptor that arrived from somewhere
else.

The second is seeking. The CRT has `_lseek`, which looks like the right
function and takes a 32 bit offset, so it stops working at two gigabytes and
does so quietly on exactly the files where it matters. `_lseeki64` is the one
to use and this module uses only that.

The third is `fchdir`, which does not exist on Windows. It is built here out of
two calls that do, and getting a descriptor to pass it needs a detour of its
own. See `fd_open` and `fd_chdir`.

Paths go in as UTF-16. A Mojo `String` is UTF-8 and the narrow `_open` takes
the process code page, which on most installs is not UTF-8, so a path with a
non-ASCII character in it would be opened under a different name than the one
asked for. `_wopen` takes the conversion out of the picture.
"""

from std.ffi import c_int, c_ssize_t, c_uint, external_call
from std.memory.address_space import AddressSpace
from std.sys import CompilationTarget
from std.sys._win import close_handle, final_path, to_utf16

# ===-----------------------------------------------------------------------===#
# CRT constants
# ===-----------------------------------------------------------------------===#

# The permission bits `_wopen` understands, which are not the POSIX ones. The
# CRT has read and write and nothing else: no execute bit, no group, no other.
# Passing it 0o666 happens to have the two bits it wants set, but only by
# accident of where they landed, so these are spelled out.
comptime _S_IREAD = 0x0100
comptime _S_IWRITE = 0x0080

# `_read` and `_write` take an unsigned int and return an int, so a single call
# cannot report more than two gigabytes moved even though it can be asked for
# more. Clamping here rather than letting it overflow is safe because every
# caller already loops: a short read is not an error and a short write is not
# either. Linux clamps its own `read` at the same value for the same reason.
comptime _MAX_TRANSFER = 0x7FFF_F000

# The two modes a descriptor can be in on Windows. The same numbers as
# `io.file.O_BINARY`, which cannot be imported here because `io` is built on top
# of this module, and which belong in the section that already spells out the
# rest of the CRT's constants.
comptime _O_TEXT = 0x4000
comptime _O_BINARY = 0x8000

# The access mode bits, and the value that means read only. The CRT packs the
# mode into the low two bits of the same int as the flags, so this is a mask
# and not a flag, and read only is the absence of the other two rather than a
# bit of its own.
comptime _O_ACCMODE = 0x0003
comptime _O_RDONLY = 0x0000

# ===-----------------------------------------------------------------------===#
# Win32 constants
# ===-----------------------------------------------------------------------===#

# What CreateFileW needs to open a directory in order to ask where it is.
# FILE_READ_ATTRIBUTES is enough for GetFinalPathNameByHandleW, and it is the
# access a directory somebody else is working in will still grant. All three
# share bits are set because the default is to share nothing, which would make
# opening a busy directory fail for a reason that has nothing to do with the
# request.
comptime _FILE_READ_ATTRIBUTES = UInt32(0x80)
comptime _FILE_SHARE_ALL = UInt32(0x7)
comptime _OPEN_EXISTING = UInt32(3)

# Without this CreateFileW cannot open a directory at all, which is the most
# surprising thing about it. The name is about backup programs and the flag is
# about nothing else.
comptime _FILE_FLAG_BACKUP_SEMANTICS = UInt32(0x0200_0000)

comptime _INVALID_HANDLE_VALUE = -1
comptime _INVALID_FILE_ATTRIBUTES = UInt32(0xFFFF_FFFF)
comptime _FILE_ATTRIBUTE_DIRECTORY = UInt32(0x10)

# ===-----------------------------------------------------------------------===#
# The cross platform surface
# ===-----------------------------------------------------------------------===#


def _open_directory(wide: List[UInt16], flags: Int) -> Int:
    """A descriptor for a directory, which the CRT will not open for you.

    `_wopen` on a directory fails with EACCES, and there is no flag that
    changes its mind. The only route to a directory handle is CreateFileW with
    FILE_FLAG_BACKUP_SEMANTICS, and `_open_osfhandle` will then take that
    handle into the descriptor table without asking what is behind it, which is
    what makes this possible at all.

    Read only, because that is the only thing POSIX lets you do with a
    directory descriptor either. `open(dir, O_WRONLY)` is EISDIR there and the
    caller here is left with the EACCES the CRT already reported.

    The descriptor owns the handle from here on. `_close` on it closes the
    handle, which is why nothing in the failure path below closes it twice.
    """
    if (flags & _O_ACCMODE) != _O_RDONLY:
        return -1

    var attributes = external_call["GetFileAttributesW", UInt32](
        wide.unsafe_ptr()
    )
    if (
        attributes == _INVALID_FILE_ATTRIBUTES
        or (attributes & _FILE_ATTRIBUTE_DIRECTORY) == 0
    ):
        return -1

    var handle = external_call["CreateFileW", Int](
        wide.unsafe_ptr(),
        _FILE_READ_ATTRIBUTES,
        _FILE_SHARE_ALL,
        # No security attributes, which is what anything not creating something
        # passes.
        OptionalPointer[NoneType, MutUntrackedOrigin](),
        _OPEN_EXISTING,
        _FILE_FLAG_BACKUP_SEMANTICS,
        # No template file, which is also only meaningful when creating.
        Int(0),
    )
    if handle == _INVALID_HANDLE_VALUE:
        return -1

    var fd = Int(
        external_call["_open_osfhandle", c_int](handle, c_int(_O_RDONLY))
    )
    if fd < 0:
        close_handle(handle)
    return fd


def fd_open(path: String, flags: Int) -> Int:
    comptime if CompilationTarget.is_windows():
        var wide = to_utf16(path.as_bytes())
        var fd = Int(
            external_call["_wopen", c_int, num_fixed_args=2](
                wide.unsafe_ptr(), c_int(flags), c_int(_S_IREAD | _S_IWRITE)
            )
        )
        # A directory is the one thing `_wopen` refuses that POSIX allows, and
        # a caller that wants one wants it in order to pass it to `fd_chdir`.
        # Only tried after the ordinary open has failed, so nothing that works
        # today pays for it, and the errno from that failure is left alone so
        # that a file which really was denied still reports what happened.
        if fd < 0:
            fd = _open_directory(wide, flags)
        # Nothing ties `wide` to the call, so say so, or the buffer can be
        # freed while the CRT is still reading the name out of it.
        _ = wide^
        return fd
    else:
        var path_str = path
        return Int(
            external_call["open", c_int, num_fixed_args=2](
                path_str.as_c_string_slice(), c_int(flags), c_int(0o666)
            )
        )


def fd_read[
    T: AnyType, origin: MutOrigin, address_space: AddressSpace
](
    fd: Int,
    buffer: Pointer[T, origin, address_space=address_space],
    count: Int,
) -> Int:
    comptime if CompilationTarget.is_windows():
        return Int(
            external_call["_read", c_int](
                c_int(fd), buffer, c_uint(min(count, _MAX_TRANSFER))
            )
        )
    else:
        return Int(external_call["read", c_ssize_t](fd, buffer, count))


def fd_write[
    T: AnyType, origin: ImmOrigin, address_space: AddressSpace
](
    fd: Int,
    buffer: Pointer[T, origin, address_space=address_space],
    count: Int,
) -> Int:
    comptime if CompilationTarget.is_windows():
        return Int(
            external_call["_write", c_int](
                c_int(fd), buffer, c_uint(min(count, _MAX_TRANSFER))
            )
        )
    else:
        return Int(external_call["write", c_ssize_t](fd, buffer, count))


def fd_close(fd: Int) -> Int:
    comptime if CompilationTarget.is_windows():
        return Int(external_call["_close", c_int](c_int(fd)))
    else:
        return Int(external_call["close", c_int](c_int(fd)))


def fd_dup(fd: Int) -> Int:
    """The lowest free descriptor, pointing at whatever `fd` points at."""
    comptime if CompilationTarget.is_windows():
        return Int(external_call["_dup", c_int](c_int(fd)))
    else:
        return Int(external_call["dup", c_int](c_int(fd)))


def fd_dup2(source: Int, target: Int) -> Int:
    """Points `target` at whatever `source` points at, closing it first."""
    comptime if CompilationTarget.is_windows():
        # The CRT returns zero on success rather than the new descriptor, which
        # POSIX returns. Callers here only ask whether it worked, so the two
        # are not reconciled. Say so, because a caller who assumed otherwise
        # would find that the successful answer looks like descriptor zero.
        return Int(external_call["_dup2", c_int](c_int(source), c_int(target)))
    else:
        return Int(external_call["dup2", c_int](c_int(source), c_int(target)))


def fd_set_binary_mode(fd: Int) -> Int:
    """Puts a descriptor into binary mode and returns the mode it was in.

    Zero on POSIX, where there is one mode, nothing to change and nothing to
    report. On Windows the answer is `_O_BINARY` or `_O_TEXT`, which is how a
    caller can find out what the mode was without a second call, and is the
    only way to find out at all.

    The standard streams are already binary by the time a program's `main` is
    entered. See `_set_standard_streams_to_binary_mode` in
    `builtin/_startup.mojo` for who does that and why.
    """
    comptime if CompilationTarget.is_windows():
        return Int(
            external_call["_setmode", c_int](c_int(fd), c_int(_O_BINARY))
        )
    else:
        return 0


def fd_seek(fd: Int, offset: Int64, whence: Int) -> Int64:
    comptime if CompilationTarget.is_windows():
        # `_lseeki64` and not `_lseek`. See the note at the top of the file.
        return external_call["_lseeki64", Int64](
            c_int(fd), offset, c_int(whence)
        )
    else:
        return external_call["lseek", Int64](fd, offset, whence)


def fd_isatty(fd: Int) -> Bool:
    comptime if CompilationTarget.is_windows():
        # Broader than the POSIX answer, because the CRT says yes for any
        # character device and that includes NUL as well as the console. The
        # question callers are really asking is whether output is worth
        # colouring, and NUL is a rare enough answer to be wrong about.
        return external_call["_isatty", c_int](c_int(fd)) != 0
    else:
        return external_call["isatty", c_int](c_int(fd)) != 0


def fd_chdir(fd: Int) raises -> Int:
    comptime if CompilationTarget.is_windows():
        # No `fchdir`, and nothing that takes a descriptor at all: the call
        # that changes directory is SetCurrentDirectoryW and it wants a path.
        # So the descriptor goes back to a handle, the handle goes back to a
        # path, and the path is what gets used. That middle step is the only
        # reason this works, because a path is the one thing a handle can
        # always be turned back into.
        #
        # Reaching a directory descriptor to pass in here needs its own detour
        # on the way out. See `_open_directory` above.
        var handle = Int(external_call["_get_osfhandle", Int](c_int(fd)))
        if handle == _INVALID_HANDLE_VALUE:
            return -1

        var path: String
        try:
            path = final_path(handle)
        except:
            return -1

        var wide = to_utf16(path.as_bytes())
        var ok = external_call["SetCurrentDirectoryW", Int32](
            wide.unsafe_ptr()
        )
        _ = wide^
        return 0 if ok != 0 else -1
    else:
        return Int(external_call["fchdir", c_int](c_int(fd)))
