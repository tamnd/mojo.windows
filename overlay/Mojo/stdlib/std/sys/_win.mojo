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

Because every path this library gives to Windows goes through the conversion,
that is also where a path too long for the classic 260 character limit is put
into the form that has no limit. Doing it at the one place they all pass through
is the point: the alternative is remembering to do it at each call, and the
calls that forget are the ones nobody tests. See `to_utf16` and `_extended`.

Getting a path back out of an open handle is here for the same reason. It is
the only way to answer either "what does this name really refer to" or "where
is this descriptor pointing", so `os.path.realpath` and the descriptor based
directory change in `sys._fd` both need it, and neither of those modules can
import the other. See `final_path`.

The fourth thing is not about Win32 at all but about the C runtime, which ends
the process rather than returning a failure when it does not like an argument.
Any module binding a CRT call that a caller could reasonably hand something
invalid has to deal with that, so the switch for it lives here too. See
`suppress_invalid_parameter`.

Nothing in this file is conditional. It only compiles on Windows and callers
are expected to have already decided that, the same way `_libc` only makes
sense on POSIX. The modules above are where the two systems get reconciled.
"""

from std.ffi import _Global, c_char, external_call

# ===-----------------------------------------------------------------------===#
# Constants
# ===-----------------------------------------------------------------------===#

comptime _CP_UTF8 = UInt32(65001)

# GetStdHandle's argument for the two descriptors that can be a console. They
# are negative numbers passed as an unsigned value, which is what the header
# does too, and are written out here rather than negated at the call.
comptime _STD_OUTPUT_HANDLE = UInt32(0xFFFFFFF5)
comptime _STD_ERROR_HANDLE = UInt32(0xFFFFFFF4)

comptime _ENABLE_VIRTUAL_TERMINAL_PROCESSING = UInt32(0x4)

comptime _FORMAT_MESSAGE_FROM_SYSTEM = UInt32(0x1000)
comptime _FORMAT_MESSAGE_IGNORE_INSERTS = UInt32(0x200)

# Long enough for every message the system has. FormatMessageW can allocate for
# you instead, with FORMAT_MESSAGE_ALLOCATE_BUFFER, but then the caller owes it
# a LocalFree and this is a failure path, which is the worst place to add a way
# to leak.
comptime _MESSAGE_CHARS = 512

# GetFinalPathNameByHandleW: the normalised name, spelled with a drive letter
# rather than with the volume GUID. Both are zero, and they are written out
# because a reader should not have to know that to see which flags are meant.
comptime _FILE_NAME_NORMALIZED = UInt32(0x0)
comptime _VOLUME_NAME_DOS = UInt32(0x0)

# How long a path is asked for before it is asked again with room for the
# answer. Long enough that the second call almost never happens and small
# enough to be a stack sized allocation if it ever becomes one.
comptime _PATH_CHARS = 512

# The prefix that turns off path parsing in the kernel, and the longer one that
# does the same for a share. Both come back from GetFinalPathNameByHandleW and
# neither is what a caller asked about. The lengths are written out because
# they are used to cut the string and both prefixes are pure ASCII.
comptime _EXTENDED_PREFIX = "\\\\?\\"
comptime _EXTENDED_PREFIX_BYTES = 4
comptime _EXTENDED_UNC_PREFIX = "\\\\?\\UNC\\"
comptime _EXTENDED_UNC_PREFIX_BYTES = 8

# Where the classic length limit starts to matter. A path is 260 characters
# counting the drive and the terminator, and a directory is twelve fewer than
# that, so that an 8.3 name still fits inside it. The lower of the two is the
# threshold everywhere here, because a name that can be created should also be
# creatable one level further down.
comptime _LONG_PATH_CHARS = 248


# ===-----------------------------------------------------------------------===#
# Text
# ===-----------------------------------------------------------------------===#


def _is_extended(wide: Span[UInt16, _]) -> Bool:
    """Whether a wide path already opens with a prefix that stops parsing.

    Two of them do. `\\\\?\\` is the one this file puts on, and putting a second
    one on would make a name out of the first. `\\\\.\\` names a device rather
    than a file, so `\\\\.\\PhysicalDrive0` is not a path with a length limit
    and nothing may be added to the front of it.
    """
    if len(wide) < 4:
        return False
    comptime backslash = UInt16(ord("\\"))
    if wide[0] != backslash or wide[1] != backslash:
        return False
    if wide[2] != UInt16(ord("?")) and wide[2] != UInt16(ord(".")):
        return False
    return wide[3] == backslash


def _is_relative(wide: Span[UInt16, _]) -> Bool:
    """Whether the length of `wide` is not yet the length Windows will measure.

    Slashes have already been turned round by the time this is asked, so a
    separator is a backslash and nothing else. Two of them at the front is a
    share or a device and is as long as it is going to get, and so is a drive
    letter with a separator after it. Everything else grows when it is resolved,
    including `C:name`, which is measured from wherever the process last was on
    C, and `\\\\name`, which picks up a drive.
    """
    comptime backslash = UInt16(ord("\\"))
    if len(wide) >= 2 and wide[0] == backslash and wide[1] == backslash:
        return False
    if len(wide) >= 3 and wide[1] == UInt16(ord(":")) and wide[2] == backslash:
        return False
    return True


def _current_directory_chars() -> Int:
    """How long the current directory is, not counting its terminator.

    Asked with no buffer, which is the documented way to be told the size, and
    the answer then includes the nul. Zero back is a failure and is reported as
    a length of zero, which makes the caller treat a relative path as though it
    were already resolved. That is the same answer it would have given before
    any of this was here.
    """
    var count = Int(
        external_call["GetCurrentDirectoryW", UInt32](
            UInt32(0), OptionalPointer[UInt16, MutUntrackedOrigin]()
        )
    )
    return count - 1 if count > 0 else 0


def _extended(wide: List[UInt16]) -> List[UInt16]:
    """A path in the form that has no length limit, or nothing.

    The prefix is not something that can be put on the front of whatever the
    caller wrote. It stops the kernel parsing the path at all, so what follows
    has to be what the parser would have produced: fully qualified, with no `.`
    or `..` left in it and no relative piece to resolve. `GetFullPathNameW` is
    that parser, run on its own, which is why it is here rather than a loop over
    the components.

    Comes back empty when the path could not be resolved, and the caller then
    uses what it already had. There is nothing better to do: a path that
    `GetFullPathNameW` will not look at is one the open after this is not going
    to like either, and failing here would turn that into a different and less
    accurate error.
    """
    var buffer = List[UInt16](length=_PATH_CHARS, fill=0)
    var count = Int(
        external_call["GetFullPathNameW", UInt32](
            wide.unsafe_ptr(),
            UInt32(_PATH_CHARS),
            buffer.unsafe_ptr(),
            OptionalPointer[NoneType, MutUntrackedOrigin](),
        )
    )

    # A count that reaches the end of the buffer is the call saying it did not
    # fit, and the number is then what it wants including the nul.
    if count >= _PATH_CHARS:
        buffer = List[UInt16](length=count, fill=0)
        count = Int(
            external_call["GetFullPathNameW", UInt32](
                wide.unsafe_ptr(),
                UInt32(count),
                buffer.unsafe_ptr(),
                OptionalPointer[NoneType, MutUntrackedOrigin](),
            )
        )
        if count >= len(buffer):
            return List[UInt16]()

    if count == 0:
        return List[UInt16]()

    # A share keeps its two leading separators in the shorter form and loses
    # them in the longer one, because `\\?\UNC\` is already saying what they
    # said.
    comptime backslash = UInt16(ord("\\"))
    var share = count >= 2 and buffer[0] == backslash and buffer[1] == backslash
    var prefix = _EXTENDED_UNC_PREFIX if share else _EXTENDED_PREFIX
    var prefix_length = (
        _EXTENDED_UNC_PREFIX_BYTES if share else _EXTENDED_PREFIX_BYTES
    )
    var start = 2 if share else 0

    var extended = List[UInt16](capacity=prefix_length + count - start + 1)
    # Both prefixes are ASCII, so one byte is one code unit.
    for byte in prefix.as_bytes():
        extended.append(UInt16(byte))
    for index in range(start, count):
        extended.append(buffer[index])
    extended.append(0)
    return extended^


def to_utf16(text: Span[Byte, _], *, is_path: Bool = True) -> List[UInt16]:
    """UTF-8 in, UTF-16 with a nul on the end out.

    Pass `is_path=False` for text that is not a path. Almost everything here is
    one, so that is the default, but an environment variable or a message is
    not and must not have its slashes rewritten or its length worried about.
    """
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

    if not is_path:
        return wide^

    comptime forward = UInt16(ord("/"))
    comptime backward = UInt16(ord("\\"))
    for index in range(Int(count)):
        if wide[index] == forward:
            wide[index] = backward

    # A long path goes to Windows in the form that has no length limit. See
    # `_extended` for what that costs and `docs/building.md` for why it is done
    # here rather than by asking the process to opt out.
    #
    # Only past the limit, and not before it. The prefix changes what a path
    # means as well as how long it can be: a device name stops being a device,
    # a trailing dot stops being stripped, and a name a person would call the
    # same is no longer the same. Below the threshold nothing needs any of that,
    # so nothing gets it, and the paths every program actually uses keep the
    # behaviour they have on this platform.
    if _is_extended(wide):
        return wide^

    # The limit is on the path Windows ends up with, not on the one it was
    # handed, so a relative path is measured with the current directory in front
    # of it and a separator between the two. Without that, a deep tree reached
    # by a short name from inside it is the one case that still fails, and it is
    # the ordinary way to work in a deep tree.
    var length = Int(count)
    if _is_relative(wide):
        length += _current_directory_chars() + 1

    if length < _LONG_PATH_CHARS:
        return wide^
    var extended = _extended(wide)
    if len(extended) == 0:
        return wide^
    return extended^


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


# ===-----------------------------------------------------------------------===#
# The invalid parameter handler
# ===-----------------------------------------------------------------------===#

# What the C runtime hands its handler: the expression that failed, the function
# it failed in, the file, the line, and a reserved word. The first three are
# wide strings and are all null in the release runtime, which is the only one
# anything here links against, so they are taken as integers and ignored.
comptime _invalid_parameter_handler = def (
    Int, Int, Int, UInt32, Int
) thin -> None


def _ignore_invalid_parameter(
    expression: Int, function: Int, file: Int, line: UInt32, reserved: Int
):
    """A handler that returns, which is the entire point of it."""
    pass


def suppress_invalid_parameter() -> _invalid_parameter_handler:
    """Stops the C runtime ending the process over an argument it dislikes.

    Most of the CRT checks its arguments, and when a check fails it calls a
    handler instead of returning a failure the way POSIX would. The handler in
    the release runtime is `__fastfail`, which raises
    STATUS_STACK_BUFFER_OVERRUN, 0xC0000409. That is not a signal, not
    something a caller can catch and not an exit code anybody chose: the
    process is gone before the call returns and nothing is printed. Passing a
    descriptor that is not open to `_isatty` is enough to trigger it.

    So a call that can be handed something invalid installs a handler that does
    nothing first, and the CRT call then returns its documented failure value
    with errno set, which is what the same call does on Linux. The handler is
    thread local, so this does not reach another thread, and the one it
    displaced is returned so that it does not reach another call either. Give
    that back to `restore_invalid_parameter` once the call is done. CPython
    does the same thing and spells it `_Py_BEGIN_SUPPRESS_IPH`.
    """
    return external_call[
        "_set_thread_local_invalid_parameter_handler",
        _invalid_parameter_handler,
    ](_ignore_invalid_parameter)


def restore_invalid_parameter(previous: _invalid_parameter_handler):
    """Puts back whatever `suppress_invalid_parameter` displaced."""
    _ = external_call[
        "_set_thread_local_invalid_parameter_handler",
        _invalid_parameter_handler,
    ](previous)


# ===-----------------------------------------------------------------------===#
# Handles
# ===-----------------------------------------------------------------------===#


def close_handle(handle: Int):
    """CloseHandle, declared in one place so that every caller agrees on it.

    `external_call` declares the function it names, and two declarations of one
    name with different argument types are a conflict. The compiler only says
    so once both have been pulled into the same module, so the report arrives
    in whichever unrelated program happened to import both, naming a line in
    `ffi` and a line in whichever of the two got there second.

    A HANDLE is opaque, so there is no wrong answer about how to spell it and
    every caller picked a different one: a pointer where the call that produced
    it returned a pointer, an integer where it returned an integer. This takes
    the integer, which is what CreateFileW gives back, and callers holding a
    pointer convert. One declaration, no clash.
    """
    _ = external_call["CloseHandle", Int32](handle)


def wait_for_single_object(handle: Int, milliseconds: UInt32) -> UInt32:
    """WaitForSingleObject, in one place for the same reason as the above.

    Two callers, a waitable timer in `time` and a child process in `os.process`,
    and the same clash waiting to happen: the timer arrives as a pointer and the
    process as an integer, so whichever of the two reached a module second was
    the one the compiler blamed. Integer here, and the timer converts.
    """
    return external_call["WaitForSingleObject", UInt32](handle, milliseconds)


# ===-----------------------------------------------------------------------===#
# Paths
# ===-----------------------------------------------------------------------===#


def _strip_extended_prefix(var path: String) -> String:
    """`\\\\?\\C:\\dir` back to `C:\\dir`, and the share form back to
    `\\\\server\\share`."""
    if path.startswith(_EXTENDED_UNC_PREFIX):
        return String("\\\\", path[byte=_EXTENDED_UNC_PREFIX_BYTES :])
    if path.startswith(_EXTENDED_PREFIX):
        return String(path[byte=_EXTENDED_PREFIX_BYTES :])
    return path^


def final_path(handle: Int) raises -> String:
    """Where an open handle actually points, as a path.

    This is the only call that resolves a whole chain of links, and it works
    from a handle rather than from a name, which is why two unrelated things
    need it. `os.path.realpath` opens the name it was given and asks this. The
    descriptor based directory change in `sys._fd` has a descriptor already and
    asks the same question of it, because Windows has no `fchdir` and the only
    way to one is to turn the descriptor back into a path.

    The name comes back in the extended `\\\\?\\` form, which is a real path and
    not one anybody wants to read or compare against, so the prefix comes off
    here. That is what CPython's `ntpath.realpath` does too. It is lossy in
    exactly one case, a result past 260 characters, which needs the prefix in
    order to be opened again. Agreeing with CPython is worth more than being
    right about a path nobody on this platform can type.
    """
    comptime flags = _FILE_NAME_NORMALIZED | _VOLUME_NAME_DOS
    var buffer = List[UInt16](length=_PATH_CHARS, fill=0)
    var count = Int(
        external_call["GetFinalPathNameByHandleW", UInt32](
            handle, buffer.unsafe_ptr(), UInt32(_PATH_CHARS), flags
        )
    )

    # A count that fills the buffer is the call saying it did not fit, and the
    # number is then what it needs including the nul. Asking again is the whole
    # of the retry, since the handle is still open and the answer cannot have
    # changed underneath it.
    if count >= _PATH_CHARS:
        buffer = List[UInt16](length=count + 1, fill=0)
        count = Int(
            external_call["GetFinalPathNameByHandleW", UInt32](
                handle, buffer.unsafe_ptr(), UInt32(count + 1), flags
            )
        )

    if count == 0:
        raise Error(error_message(last_error()))

    var resolved = to_utf8(Span(unsafe_ptr=buffer.unsafe_ptr(), length=count))
    _ = buffer^
    return _strip_extended_prefix(resolved^)


# ===-----------------------------------------------------------------------===#
# Console
# ===-----------------------------------------------------------------------===#


def _enable_virtual_terminal(id: UInt32) -> Bool:
    """Asks one of the standard handles to read escape sequences.

    Returns whether whatever is on the other end understands them once this has
    run, which is `False` for anything that is not a console and for a console
    that refuses.
    """
    var handle = external_call["GetStdHandle", Int](id)
    var mode = UInt32(0)

    # Anything that is not a console fails here, and that is the test. Asking
    # the descriptor whether it is a character device is the other way to ask
    # and it is the wrong one, because a pipe and the null device both say yes
    # and neither of them wants escape sequences written into it.
    if external_call["GetConsoleMode", Int32](handle, Pointer(to=mode)) == 0:
        return False

    if (mode & _ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0:
        return True

    return (
        external_call["SetConsoleMode", Int32](
            handle, mode | _ENABLE_VIRTUAL_TERMINAL_PROCESSING
        )
        != 0
    )


def _prepare_console() -> Bool:
    """Puts the console into the state the rest of the library writes for.

    Two separate things, done together because they are both about the console
    and both want doing exactly once.

    The code page is what a console reads bytes in. It defaults to the system's,
    which in most of the world is not UTF-8, and every string this library
    hands over is UTF-8, so without this a program that prints anything outside
    ASCII shows the wrong characters, and which wrong characters depends on
    where the machine was set up. That is the worst kind of bug to receive a
    report about.

    Escape sequences are on in Windows Terminal and off in the old console
    host, so the same coloured output that works in one prints its control
    codes as text in the other. Turning them on is a request the console
    either grants or refuses, and the answer is what comes back from here.

    Both of these belong to the console rather than to this process, so they
    outlive the program the way `chcp` does. Every program that colours its
    output on Windows makes that trade, and it is the reason this runs when
    something is first written to a console rather than at startup: a Mojo
    library loaded into a host that never prints leaves the console alone.
    """
    _ = external_call["SetConsoleOutputCP", Int32](_CP_UTF8)
    _ = external_call["SetConsoleCP", Int32](_CP_UTF8)

    # Standard error gets the same treatment and its answer is dropped, because
    # the library has one switch for colour and standard output is what that
    # switch is about. The two are the same console nearly always.
    _ = _enable_virtual_terminal(_STD_ERROR_HANDLE)
    return _enable_virtual_terminal(_STD_OUTPUT_HANDLE)


comptime _CONSOLE = _Global["WINDOWS_CONSOLE", _prepare_console]


def console_takes_escapes() -> Bool:
    """Sets the console up on the first call, and says what stdout can render.

    Every write to standard output or standard error goes through here, which
    is what makes the setting up happen at all, and all but the first of them
    reads back an answer that is already known. Callers that only want to know
    whether to colour something can ignore that they are also the reason the
    console is in the right state.
    """
    if __is_run_in_comptime_interpreter:
        # A program being evaluated by the compiler has no console of its own
        # to set up, and could not do it here anyway: the answer is remembered
        # in a table the interpreter has no way to reach. Whatever the
        # compiler's own output is doing is the compiler's business.
        return False

    try:
        return _CONSOLE.get_or_create_ptr()[]
    except:
        # `_Global` allocates, so the only way here is out of memory, and a
        # program in that state has a real problem and does not need escape
        # sequences added to it.
        return False
