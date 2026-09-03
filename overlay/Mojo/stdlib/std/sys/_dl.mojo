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
"""Loading a dynamic library, on the two operating systems that disagree
about how.

`_libc` is where the POSIX bindings live and it should stay that way, because
nothing in it is conditional and that is what makes it readable. This module is
the layer above: one set of names, `dlopen` underneath on POSIX and the Win32
loader underneath on Windows, so that `ffi` can load a library without knowing
which one it is running on.

Four of the five names map across almost exactly. `dlopen` is `LoadLibraryExW`,
`dlsym` is `GetProcAddress`, `dlclose` is `FreeLibrary`, and the arguments line
up once the encoding and the success convention are dealt with.

The fifth does not map at all, and it is worth saying why rather than leaving it
looking like an oversight. `dlerror` hands back a `char*` that stays valid until
the next call on the same thread, and the caller reads it without owning it.
Windows has nothing like that. It has an error code in thread local storage and
`FormatMessageW`, which builds a message into a buffer somebody has to supply.
There is no pointer to hand back. So the pair of calls that everything actually
does with `dlerror`, clear the error and then read it, are what this module
exposes, and `dl_error` returns an owned `String` rather than a borrowed
pointer. That is the same operation on both systems and it is the only shape
that is.
"""

from std.ffi import CStringSlice, c_char, c_int, external_call
from std.sys import CompilationTarget
from std.sys._libc import dlclose, dlerror, dlopen, dlsym
from std.sys._win import clear_last_error, error_message, last_error, to_utf16

# ===-----------------------------------------------------------------------===#
# Win32 constants
# ===-----------------------------------------------------------------------===#

# Look in the directories the process has registered rather than in the current
# directory. This is the flag that makes `LoadLibraryExW` safe to hand an
# attacker influenced name, and it is also the flag that fails with
# ERROR_INVALID_PARAMETER when the path is relative, which is why the code below
# only passes it when the path is absolute.
comptime _LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = UInt32(0x1000)

comptime _BACKSLASH = Byte(ord("\\"))
comptime _SLASH = Byte(ord("/"))
comptime _COLON = Byte(ord(":"))


# ===-----------------------------------------------------------------------===#
# The cross platform surface
# ===-----------------------------------------------------------------------===#


def dl_open(
    filename: OptionalPointer[mut=False, c_char, ImmUntrackedOrigin],
    flags: c_int,
) -> OptionalPointer[NoneType, MutUntrackedOrigin]:
    comptime if CompilationTarget.is_windows():
        # The RTLD flags are accepted and dropped. Windows has no equivalent of
        # any of them: symbol resolution is eager and per module, and there is
        # no global namespace for RTLD_GLOBAL to add to. Dropping them silently
        # is the right call anyway, because the alternative is every caller
        # writing the same platform test around a value that cannot mean
        # anything here.
        _ = flags
        return _win_open(filename)
    else:
        return dlopen(filename, flags)


def dl_sym[
    result_type: AnyType = NoneType
](
    handle: OptionalPointer[NoneType, _],
    name: ImmPointer[c_char, _],
    out result: OptionalPointer[result_type, MutUntrackedOrigin],
):
    comptime if CompilationTarget.is_windows():
        # No conversion on the name. GetProcAddress is the one Win32 function in
        # this file with no wide variant, because a symbol name in a PE export
        # table is bytes and not text.
        result = external_call["GetProcAddress", type_of(result)](handle, name)
    else:
        result = dlsym[result_type](handle, name)


def dl_close(handle: OptionalPointer[mut=True, NoneType, _]) -> c_int:
    comptime if CompilationTarget.is_windows():
        # FreeLibrary answers the opposite question: nonzero means it worked,
        # where dlclose returns zero. Every caller in the tree throws the result
        # away, so this costs nothing today, but a function called dl_close has
        # to mean what dlclose means or the next caller gets it backwards.
        var ok = external_call["FreeLibrary", Int32](handle)
        return c_int(0) if ok != 0 else c_int(-1)
    else:
        return dlclose(handle)


def dl_clear_error():
    comptime if CompilationTarget.is_windows():
        clear_last_error()
    else:
        _ = dlerror()


def dl_error() -> Optional[String]:
    comptime if CompilationTarget.is_windows():
        var code = last_error()
        if code == 0:
            return None
        return error_message(code)
    else:
        var message = dlerror()
        if not message:
            return None
        return String(unsafe_from_utf8_ptr=message.value().as_imm())


# ===-----------------------------------------------------------------------===#
# Windows
# ===-----------------------------------------------------------------------===#


def _win_open(
    filename: OptionalPointer[mut=False, c_char, ImmUntrackedOrigin],
) -> OptionalPointer[NoneType, MutUntrackedOrigin]:
    if not filename:
        # `dlopen(NULL)` asks for a handle that finds any symbol already loaded
        # into the process. Windows has no such handle and cannot be made to
        # have one, because its loader resolves per module rather than into one
        # flat namespace. GetModuleHandleW(NULL) gives the handle of the
        # executable itself, so a program looking up its own symbols gets what
        # it expected and a program hoping to reach into a library somebody else
        # loaded does not. That is a real difference and this is the one place
        # in the file that is a best effort rather than a translation.
        return external_call[
            "GetModuleHandleW", OptionalPointer[NoneType, MutUntrackedOrigin]
        ](OptionalPointer[UInt16, ImmUntrackedOrigin]())

    var text = StringSlice(
        unsafe_from_utf8=CStringSlice(unsafe_from_ptr=filename.value())
    )
    var bytes = text.as_bytes()
    var wide = to_utf16(bytes)
    var flags = (
        _LOAD_LIBRARY_SEARCH_DEFAULT_DIRS if _is_absolute(bytes) else UInt32(0)
    )
    var handle = external_call[
        "LoadLibraryExW", OptionalPointer[NoneType, MutUntrackedOrigin]
    ](
        wide.unsafe_ptr(),
        # The reserved hFile argument, which has been required to be null since
        # Windows NT and is still in the signature.
        OptionalPointer[NoneType, MutUntrackedOrigin](),
        flags,
    )
    # Nothing ties `wide` to the call, so say so, or the buffer can be freed
    # while the loader is still reading the name out of it.
    _ = wide^
    return handle


def _is_separator(byte: Byte) -> Bool:
    return byte == _BACKSLASH or byte == _SLASH


def _is_absolute(path: Span[Byte, _]) -> Bool:
    # Fully qualified means one of exactly two shapes, and one leading
    # separator is not either of them. `\windows\system32` is rooted at the
    # current drive rather than at a named one, so it means something different
    # depending on the process state, and the LOAD_LIBRARY_SEARCH flags reject
    # it along with everything else that is not fully qualified.
    if len(path) >= 2 and _is_separator(path[0]) and _is_separator(path[1]):
        # A UNC name, rooted at a server.
        return True
    if len(path) >= 3 and path[1] == _COLON and _is_separator(path[2]):
        # The ordinary drive letter form.
        return True
    return False
