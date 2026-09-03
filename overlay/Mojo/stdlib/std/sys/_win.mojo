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
"""The two things every piece of Windows support in the standard library needs.

Text goes in and out of Win32 as UTF-16, and a Mojo `String` is UTF-8, so
somebody has to convert. Errors come back as a number and turning that number
into a sentence takes a call. Both of those come up in every module that binds
anything on Windows, which is why they are here rather than in whichever module
happened to want them first.

Nothing in this file is conditional. It only compiles on Windows and callers
are expected to have already decided that, the same way `_libc` only makes
sense on POSIX. The modules above are where the two systems get reconciled.
"""

from std.ffi import c_char, external_call

# ===-----------------------------------------------------------------------===#
# Constants
# ===-----------------------------------------------------------------------===#

comptime _CP_UTF8 = UInt32(65001)

comptime _FORMAT_MESSAGE_FROM_SYSTEM = UInt32(0x1000)
comptime _FORMAT_MESSAGE_IGNORE_INSERTS = UInt32(0x200)

# Long enough for every message the system has. FormatMessageW can allocate for
# you instead, with FORMAT_MESSAGE_ALLOCATE_BUFFER, but then the caller owes it
# a LocalFree and this is a failure path, which is the worst place to add a way
# to leak.
comptime _MESSAGE_CHARS = 512


# ===-----------------------------------------------------------------------===#
# Text
# ===-----------------------------------------------------------------------===#


def to_utf16(text: Span[Byte, _]) -> List[UInt16]:
    """UTF-8 in, UTF-16 with a nul on the end out."""
    # Forward slashes become backslashes on the way through. The slashes
    # matter: the Win32 file APIs take either, but LoadLibraryEx with any of
    # the LOAD_LIBRARY_SEARCH flags rejects a name containing a forward slash,
    # and a Mojo program is very likely to have built its path with them. Doing
    # it here rather than at that one call site keeps every path this library
    # hands to Windows in the same shape, which is worth more than the handful
    # of conversions it saves.
    #
    # Sized rather than measured. The usual way to call this is twice, once
    # with a null buffer to be told the length and once to do the work, but
    # UTF-8 never produces more UTF-16 code units than it had bytes, so the
    # length is already known: one byte becomes at most one unit, and the four
    # byte sequences that become two units had four bytes to pay for them. One
    # more for the nul, because the count based form does not add one and every
    # caller wants a nul terminated string.
    var wide = List[UInt16](length=len(text) + 1, fill=0)
    if len(text) == 0:
        return wide^

    var count = external_call["MultiByteToWideChar", Int32](
        _CP_UTF8,
        UInt32(0),
        text.unsafe_ptr(),
        Int32(len(text)),
        wide.unsafe_ptr(),
        Int32(len(text)),
    )
    if count <= 0:
        return List[UInt16](length=1, fill=0)

    comptime forward = UInt16(ord("/"))
    comptime backward = UInt16(ord("\\"))
    for index in range(Int(count)):
        if wide[index] == forward:
            wide[index] = backward
    return wide^


def to_utf8(wide: Span[UInt16, _]) -> String:
    """UTF-16 in, a Mojo `String` out."""
    # Sized the same way as the other direction. Three bytes per code unit is
    # the worst case, because the only sequences that reach four bytes come
    # from a surrogate pair and a pair is two code units.
    var bytes = List[Byte](length=3 * len(wide) + 1, fill=0)
    if len(wide) == 0:
        return String()

    var count = external_call["WideCharToMultiByte", Int32](
        _CP_UTF8,
        UInt32(0),
        wide.unsafe_ptr(),
        Int32(len(wide)),
        bytes.unsafe_ptr(),
        Int32(3 * len(wide)),
        # The replacement character and the flag saying one was used, neither
        # of which CP_UTF8 accepts. It has its own answer for anything it
        # cannot encode and rejects the call outright if you try to supply one.
        OptionalPointer[c_char, ImmUntrackedOrigin](),
        OptionalPointer[Int32, MutUntrackedOrigin](),
    )
    if count <= 0:
        return String()

    # Lossy rather than strict. CP_UTF8 with no flags already replaces anything
    # unpaired with U+FFFD, so there should be nothing left to be lossy about,
    # and the callers here are mostly building error messages, where raising
    # would be a poor trade for a case that cannot happen.
    var result = String(
        from_utf8_lossy=Span(unsafe_ptr=bytes.unsafe_ptr(), length=Int(count))
    )
    _ = bytes^
    return result^


def wide_len(wide: Span[UInt16, _]) -> Int:
    """The length of a nul terminated wide string, not counting the nul."""
    var length = 0
    while length < len(wide) and wide[length] != 0:
        length += 1
    return length


# ===-----------------------------------------------------------------------===#
# Errors
# ===-----------------------------------------------------------------------===#


def last_error() -> UInt32:
    """The calling thread's last error code."""
    return external_call["GetLastError", UInt32]()


def clear_last_error():
    """Sets the calling thread's last error code to zero."""
    external_call["SetLastError", NoneType](UInt32(0))


def error_message(code: UInt32) -> String:
    """The system's sentence for an error code, without its trailing newline.
    """
    var buffer = List[UInt16](length=_MESSAGE_CHARS, fill=0)
    var count = Int(
        external_call["FormatMessageW", UInt32](
            _FORMAT_MESSAGE_FROM_SYSTEM | _FORMAT_MESSAGE_IGNORE_INSERTS,
            # No source module, because the message is coming from the system.
            OptionalPointer[NoneType, ImmUntrackedOrigin](),
            code,
            # Language zero, which asks for the caller's language and falls back
            # through the system's to US English.
            UInt32(0),
            buffer.unsafe_ptr(),
            UInt32(_MESSAGE_CHARS),
            # The insert arguments, which IGNORE_INSERTS says will not be read.
            OptionalPointer[NoneType, MutUntrackedOrigin](),
        )
    )

    # System messages come with a trailing newline, which is right for printing
    # one on its own and wrong for putting one inside a sentence, and these are
    # always going inside a sentence.
    comptime carriage_return = UInt16(ord("\r"))
    comptime newline = UInt16(ord("\n"))
    comptime space = UInt16(ord(" "))
    while count > 0 and (
        buffer[count - 1] == carriage_return
        or buffer[count - 1] == newline
        or buffer[count - 1] == space
    ):
        count -= 1

    if count == 0:
        # No message for this code, which happens for codes the system does not
        # own. The number on its own is still worth more than an empty string.
        return String("Windows error ", code)

    var message = to_utf8(Span(unsafe_ptr=buffer.unsafe_ptr(), length=count))
    _ = buffer^
    return message^
