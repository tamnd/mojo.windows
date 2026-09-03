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

The second is seeking. The CRT has `_lseek`, which looks like the right
function and takes a 32 bit offset, so it stops working at two gigabytes and
does so quietly on exactly the files where it matters. `_lseeki64` is the one
to use and this module uses only that.

The third is `fchdir`, which does not exist on Windows and cannot be built out
of anything that does. See `fd_chdir` below for why.

Paths go in as UTF-16. A Mojo `String` is UTF-8 and the narrow `_open` takes
the process code page, which on most installs is not UTF-8, so a path with a
non-ASCII character in it would be opened under a different name than the one
asked for. `_wopen` takes the conversion out of the picture.
"""

from std.ffi import c_int, c_ssize_t, c_uint, external_call
from std.memory.address_space import AddressSpace
from std.sys import CompilationTarget
from std.sys._win import to_utf16

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

# ===-----------------------------------------------------------------------===#
# The cross platform surface
# ===-----------------------------------------------------------------------===#


def fd_open(path: String, flags: Int) -> Int:
    comptime if CompilationTarget.is_windows():
        var wide = to_utf16(path.as_bytes())
        var fd = external_call["_wopen", c_int, num_fixed_args=2](
            wide.unsafe_ptr(), c_int(flags), c_int(_S_IREAD | _S_IWRITE)
        )
        # Nothing ties `wide` to the call, so say so, or the buffer can be
        # freed while the CRT is still reading the name out of it.
        _ = wide^
        return Int(fd)
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
        # There is no way to write this, and the reason sits one step further
        # back than it looks. `fchdir` needs a descriptor for a directory, and
        # on Windows there is no such thing: `_wopen` on a directory fails with
        # EACCES, so a caller cannot get as far as having something to pass in.
        # Going around the CRT does not help either, because the only way to a
        # directory handle is `CreateFileW` with FILE_FLAG_BACKUP_SEMANTICS and
        # the CRT will not take one of those into its descriptor table.
        #
        # Raising rather than returning a failure code, because an errno would
        # say the descriptor was bad when the truth is that the operation does
        # not exist, and that would send whoever hits it looking in the wrong
        # place.
        _ = fd
        raise Error(
            "fchdir is not available on Windows, because a directory cannot be"
            " opened as a file descriptor there. Use chdir with a path."
        )
    else:
        return Int(external_call["fchdir", c_int](c_int(fd)))
