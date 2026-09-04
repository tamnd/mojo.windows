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
"""Implements os methods for dealing with processes.

Example:

```mojo
from std.os import Process
from std.collections import List
_ = Process.run("echo", ["== TEST_ECHO"])
```

Windows is spawn rather than fork, and the shapes line up better than they
might: `posix_spawnp` is already a spawn, so `run` maps onto `CreateProcessW`
without anything being turned inside out. What does not line up is signals,
which Windows does not have. See `_windows_status` and `_kill`.

A `Pipe` is the same idea on both, and only the moment when close on exec is
decided moves. See `fd_pipe` and `fd_set_inheritable` in `sys._fd`. Note that
nothing here hands an end of one to a child on Windows yet, because
`_windows_spawn` passes no handles down, so on that side the flag is honest
rather than load bearing.
"""
from std.collections import List, Optional
from std.collections.string import StringSlice
from std.sys import CompilationTarget
from std.sys._libc import (
    waitpid,
    posix_spawnp,
    _get_environ,
    kill,
    SignalCodes,
    close,
    WaitFlags,
)
from std.sys._fd import fd_pipe, fd_set_inheritable
from std.ffi import (
    c_char,
    c_int,
    c_pid_t,
    external_call,
    get_errno,
    CStringSlice,
)
from std.sys import size_of
from std.sys._win import (
    close_handle,
    error_message,
    last_error,
    to_utf16,
    wait_for_single_object,
)
from .os import abort, sep


# ===----------------------------------------------------------------------=== #
# Process comm.
# ===----------------------------------------------------------------------=== #


struct ProcessStatus(Copyable, ImplicitlyCopyable, Movable):
    """Represents the termination status of a process.

    This struct is returned by `poll()` and `wait()`.
    """

    var exit_code: Optional[Int]
    """The exit code if the process terminated normally."""

    var term_signal: Optional[Int]
    """The signal number that terminated the process."""

    def __init__(
        out self,
        exit_code: Optional[Int] = None,
        term_signal: Optional[Int] = None,
    ):
        """Initializes a new `ProcessStatus`.

        Args:
            exit_code: The exit code if the process terminated normally.
            term_signal: The signal number that terminated the process.
        """
        self.exit_code = exit_code
        self.term_signal = term_signal

    @staticmethod
    def running() -> Self:
        """Creates a status for a running process.

        Returns:
            A `ProcessStatus` for a running process.
        """
        return Self()

    def has_exited(self) -> Bool:
        """Checks if the process has terminated.

        Returns:
            True if the process has terminated, either normally or by a signal.
        """
        return Bool(self.exit_code) or Bool(self.term_signal)


struct Pipe:
    """Create a pipe for interprocess communication.

    Example usage:
    ```mojo
    from std.os.process import Pipe

    def main() raises:
        var pipe = Pipe()
        pipe.write_bytes("TEST".as_bytes())
    ```
    """

    var fd_in: Optional[FileDescriptor]
    """File descriptor for pipe input."""
    var fd_out: Optional[FileDescriptor]
    """File descriptor for pipe output."""

    def __init__(
        out self,
        in_close_on_exec: Bool = True,
        out_close_on_exec: Bool = True,
    ) raises:
        """Initializes a new `Pipe`.

        Args:
            in_close_on_exec: Close the read side of pipe if an `exec` syscall
              is issued in the process.
            out_close_on_exec: Close the write side of pipe if an `exec`
              syscall is issued in the process.

        Raises:
            Error: If the pipe could not be created or configured.
        """
        var pipe_fds = Array[c_int, 2](fill=0)
        if fd_pipe(pipe_fds.unsafe_ptr()) < 0:
            raise Error("Failed to create pipe")

        # Both ends are set either way rather than only the ones being closed,
        # because on Windows the pipe arrives private and asking for it to be
        # inherited is a call somebody has to make. On POSIX clearing a flag
        # that `pipe` left clear costs one call and does nothing.
        if not self._set_close_on_exec(pipe_fds[0], in_close_on_exec):
            _ = close(pipe_fds[0])
            _ = close(pipe_fds[1])
            raise Error("Failed to configure input pipe close on exec")

        if not self._set_close_on_exec(pipe_fds[1], out_close_on_exec):
            _ = close(pipe_fds[0])
            _ = close(pipe_fds[1])
            raise Error("Failed to configure output pipe close on exec")

        self.fd_in = FileDescriptor(Int(pipe_fds[0]))
        self.fd_out = FileDescriptor(Int(pipe_fds[1]))

    def __deinit__(deinit self):
        """Ensures pipes input and output file descriptors are closed, when the object is destroyed.
        """
        self.set_input_only()
        self.set_output_only()

    @staticmethod
    def _set_close_on_exec(fd: c_int, on: Bool) -> Bool:
        return fd_set_inheritable(Int(fd), not on) == 0

    @always_inline
    def set_input_only(mut self):
        """Close the output descriptor/ channel for this side of the pipe."""
        if self.fd_out:
            _ = close(Int32(rebind[Int](self.fd_out.value())))
            self.fd_out = None

    @always_inline
    def set_output_only(mut self):
        """Close the input descriptor/ channel for this side of the pipe."""
        if self.fd_in:
            _ = close(Int32(rebind[Int](self.fd_in.value())))
            self.fd_in = None

    @always_inline
    def write_bytes(mut self, bytes: Span[Byte, _]) raises:
        """Writes a span of bytes to the pipe.

        Args:
            bytes: The byte span to write to this pipe.

        Raises:
            Error: If called on a read-only pipe.
        """
        if self.fd_out:
            self.fd_out.value().write_bytes(bytes)
        else:
            raise Error("Can not write from read only side of pipe")

    @always_inline
    def read_bytes(mut self, buffer: MutSpan[Byte, _]) raises -> Int:
        """Read a number of bytes from this pipe.

        Args:
            buffer: Span[Byte] of length n where to store read bytes. n = number of bytes to read.

        Returns:
            Actual number of bytes read.

        Raises:
            Error: If the pipe is in write-only mode.
        """
        if self.fd_in:
            return self.fd_in.value().read_bytes(buffer)

        raise Error("Can not read from write only side of pipe")


# ===----------------------------------------------------------------------=== #
# Windows
# ===----------------------------------------------------------------------=== #

# What WaitForSingleObject says. Zero is the object it was asked about, which
# for a process handle means the process has exited, and 258 is the timeout
# expiring, which for a zero timeout means it has not.
comptime _WAIT_OBJECT_0 = UInt32(0)
comptime _WAIT_TIMEOUT = UInt32(258)
comptime _INFINITE = UInt32(0xFFFF_FFFF)

# The code TerminateProcess is asked to leave behind. Windows itself uses this
# one when a console process is killed by Ctrl+C, and it is in the range that
# `_windows_status` reads as a process that was killed rather than one that
# chose its own exit code, which is what a caller of `kill` means.
comptime _STATUS_CONTROL_C_EXIT = UInt32(0xC000_013A)

# Where the severity lives in an NTSTATUS. Three is error, which is what an
# unhandled exception leaves behind as the exit code of the process it killed.
comptime _NTSTATUS_SEVERITY_SHIFT = 30
comptime _NTSTATUS_SEVERITY_ERROR = UInt32(3)

comptime _QUOTE = Byte(ord('"'))
comptime _BACKSLASH = Byte(ord("\\"))
comptime _SPACE = Byte(ord(" "))
comptime _TAB = Byte(ord("\t"))


@fieldwise_init
struct _startupinfow(Copyable, Defaultable):
    """STARTUPINFOW, which CreateProcessW requires and this code does not use.

    Every field but the first says where to put a window, what to call it, or
    which handles to hand the child, and none of that is being asked for here.
    The first field is the size of the structure, which is how the call knows
    which version of it was passed, and it is the only one that has to be right.

    Thirteen words rather than twenty one named fields, because naming them
    would suggest somebody reads them. The size is checked below against what
    the header says, so a wrong `cb` would be a compile error rather than a call
    that fails for a reason nobody would guess.
    """

    var words: Array[UInt64, 13]
    """The whole structure, zero apart from the size in the first four bytes."""

    def __init__(out self):
        """Zeroed, with the size filled in."""
        self.words = Array[UInt64, 13](fill=0)
        self.words[0] = UInt64(size_of[Self]())


@fieldwise_init
struct _process_information(Copyable, Defaultable):
    """What CreateProcessW hands back.

    Two handles, and the caller owns both of them. The thread handle is of no
    use to anything here and is closed as soon as the call returns, because
    holding it would keep the thread object alive for as long as the `Process`
    lives for no reason at all.
    """

    var process: Int
    """Handle to the new process."""
    var thread: Int
    """Handle to its initial thread."""
    var process_id: UInt32
    """The id of the new process."""
    var thread_id: UInt32
    """The id of its initial thread."""

    def __init__(out self):
        """Zeroed, for the call to fill in."""
        self.process = 0
        self.thread = 0
        self.process_id = 0
        self.thread_id = 0


@always_inline
def _assert_windows_layouts():
    comptime assert (
        size_of[_startupinfow]() == 104
    ), "STARTUPINFOW is 104 bytes"
    comptime assert (
        size_of[_process_information]() == 24
    ), "PROCESS_INFORMATION is 24 bytes"


def _quote_for_windows(arg: StringSlice) -> String:
    """One argument, spelled so that the child gets it back unchanged.

    Windows passes a command line rather than an argument vector, and every
    process splits that line up again on its own. Nearly all of them do it with
    CommandLineToArgvW, or with the identical code in the C runtime's startup,
    so those are the rules being written to here: a run of backslashes is
    literal unless a quote follows it, in which case each one has to be doubled,
    and a quote itself is escaped by a backslash.

    An argument with no space, tab or quote in it needs none of that and is
    passed through, which is nearly always the case and keeps a command line
    readable when somebody prints one. The empty argument is the exception,
    because with no quotes around it there would be nothing there to split.
    """
    var bytes = arg.as_bytes()
    var needs_quotes = len(bytes) == 0
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte == _SPACE or byte == _TAB or byte == _QUOTE:
            needs_quotes = True
            break
    if not needs_quotes:
        return String(arg)

    var out = List[Byte]()
    out.append(_QUOTE)
    var pending = 0
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte == _BACKSLASH:
            pending += 1
            continue
        if byte == _QUOTE:
            # The run sitting in front of a quote has to be doubled, and then
            # the quote itself escaped.
            for _ in range(2 * pending + 1):
                out.append(_BACKSLASH)
        else:
            for _ in range(pending):
                out.append(_BACKSLASH)
        pending = 0
        out.append(byte)
    # A run at the very end lands in front of the closing quote, which counts.
    for _ in range(2 * pending):
        out.append(_BACKSLASH)
    out.append(_QUOTE)
    return String(unsafe_from_utf8=Span(out))


def _windows_command_line(path: StringSlice, argv: List[String]) -> String:
    """The whole command line, program first.

    lpApplicationName is left null so that CreateProcessW does its own search of
    the application directory, the working directory, the system directories and
    PATH, which is the nearest thing to what `posix_spawnp` does on the other
    side. The price of that is that the first token of this line has to be the
    program, and has to be quoted well enough that the search is not ambiguous,
    which is what `_quote_for_windows` is for.

    The POSIX arm puts the base name in argv zero and the full path in the call.
    There is nowhere to put both here, so the full path goes in, which is what
    nearly every Windows program does and is what the child reads back as its
    own argv zero.
    """
    var line = _quote_for_windows(path)
    for arg in argv:
        line += " "
        line += _quote_for_windows(arg)
    return line^


def _windows_spawn(path: StringSlice, argv: List[String]) raises -> Int:
    """Starts the process and returns an open handle to it."""
    _assert_windows_layouts()

    var line = _windows_command_line(path, argv)
    # CreateProcessW is allowed to write to the command line it is handed, and
    # is documented to do so when lpApplicationName is null, so the buffer has
    # to be ours and has to be writable. `to_utf16` already returns a fresh one.
    var wide = to_utf16(line.as_bytes())

    var startup = _startupinfow()
    var info = _process_information()
    var ok = external_call["CreateProcessW", Int32](
        # No application name, so the program comes out of the command line.
        OptionalPointer[UInt16, ImmUntrackedOrigin](),
        wide.unsafe_ptr(),
        # No security attributes for the process or for the thread, so neither
        # handle is inheritable, and nothing here starts a grandchild.
        OptionalPointer[NoneType, MutUntrackedOrigin](),
        OptionalPointer[NoneType, MutUntrackedOrigin](),
        # Not inheriting handles. `posix_spawnp` does pass the open descriptors
        # down without being asked, but nothing in the library relies on that,
        # and turning it on here would hand every open file in the parent to
        # every child.
        Int32(0),
        # No creation flags, so the child shares this console.
        UInt32(0),
        # No environment block, which means inherit. `_putenv_s` keeps the Win32
        # copy in step with the C runtime's, so a `setenv` in the parent is
        # visible to the child, same as it is on the other platforms.
        OptionalPointer[NoneType, ImmUntrackedOrigin](),
        # No working directory, which means inherit that too.
        OptionalPointer[UInt16, ImmUntrackedOrigin](),
        Pointer(to=startup),
        Pointer(to=info),
    )
    var code = last_error()
    _ = wide^

    if ok == 0:
        raise Error("Failed to execute ", path, ": ", error_message(code))

    # Nothing wants the thread, and holding the handle would keep the thread
    # object alive for the life of the `Process` for no reason.
    close_handle(info.thread)
    return info.process


def _windows_status(handle: Int, *, blocking: Bool) raises -> ProcessStatus:
    """Whether the process has finished, and how.

    Asking the handle rather than asking for the exit code, because
    GetExitCodeProcess reports a process that is still running as STILL_ACTIVE,
    which is the number 259, and a process that exited with 259 is then
    indistinguishable from one that has not exited at all. WaitForSingleObject
    answers the same question without that hole in it, and the exit code is only
    read once it has said the process is gone.

    Windows has no signals, so there is no honest `term_signal` to report. What
    it has instead is that a process killed by an unhandled exception exits with
    the NTSTATUS of that exception, and the severity field of an NTSTATUS is
    error for every one of them: an illegal instruction, an access violation, a
    stack overflow. That is the closest thing there is to being killed by a
    signal, and it is what the trap instruction behind `abort` comes back as, so
    it is reported as `term_signal` with the status in it.

    The gap is worth knowing about. A program that exits normally with a code in
    that range reads here as one that crashed, and there is no second thing to
    look at that would tell the two apart. Nothing picks an exit code up in
    that range on purpose.
    """
    var waited = wait_for_single_object(
        handle, _INFINITE if blocking else UInt32(0)
    )
    if waited == _WAIT_TIMEOUT:
        return ProcessStatus.running()
    if waited != _WAIT_OBJECT_0:
        raise Error("WaitForSingleObject failed: ", error_message(last_error()))

    var code = UInt32(0)
    var ok = external_call["GetExitCodeProcess", Int32](
        handle, Pointer(to=code)
    )
    if ok == 0:
        raise Error("GetExitCodeProcess failed: ", error_message(last_error()))

    if (code >> _NTSTATUS_SEVERITY_SHIFT) == _NTSTATUS_SEVERITY_ERROR:
        return ProcessStatus(term_signal=Optional(Int(code)))
    return ProcessStatus(exit_code=Optional(Int(code)))


# ===----------------------------------------------------------------------=== #
# Process execution
# ===----------------------------------------------------------------------=== #
struct Process:
    """Create and manage child processes from file executables.

    Example usage:
    ```mojo
    from std.os.process import Process

    def main() raises:
        var child_process = Process.run("ls", ["-lha"])
        if child_process.interrupt():
            print("Successfully interrupted.")
    ```
    """

    var child_pid: c_pid_t
    """Child process id. Zero on Windows, where the handle is what identifies
    the child: the process id is also handed back, but it is not enough to wait
    on and it stops meaning anything the moment the process exits."""

    var handle: Int
    """Open handle to the child, on Windows. Zero on every other platform."""

    var status: Optional[ProcessStatus]
    """Cached status of the process. `None` if the process has not been waited on yet."""

    def __init__(out self, child_pid: c_pid_t, handle: Int = 0):
        """Struct to manage metadata about child process.
        Use the `run` static method to create new process.

        Args:
          child_pid: The pid of child process returned by `posix_spawnp` that the struct will manage.
          handle: The handle returned by `CreateProcessW`. Unused off Windows.
        """

        self.child_pid = child_pid
        self.handle = handle
        self.status = None

    def __deinit__(deinit self):
        """Waits for the process to exit when the `Process` object is destroyed.
        """
        try:
            _ = self.wait()
        except:
            # Errors in __deinit__ should be suppressed.
            pass

        # The POSIX side has nothing to release, because waiting on a pid is
        # what releases it. A handle is a reference to the process object and
        # has to be given back by hand, or the exited process stays in the
        # table for as long as this program runs.
        comptime if CompilationTarget.is_windows():
            if self.handle != 0:
                close_handle(self.handle)

    def _kill(mut self, signal: Int) -> Bool:
        # We need to check the "cached" status to avoid trying to
        # kill a process after already having waited upon its exit.
        # Such a process no longer exists and its pid could be reused
        if self.status and self.status.value().has_exited():
            return False

        comptime if CompilationTarget.is_windows():
            # Windows has no signals. TerminateProcess is the only way to end
            # another process from outside, it cannot be caught or handled, and
            # so it is the right answer for `kill` and the wrong one for the
            # other two: a hangup and an interrupt are both requests the program
            # is allowed to refuse, and there is nothing here that would give it
            # the chance. The nearest call is GenerateConsoleCtrlEvent, which
            # acts on a whole console process group rather than on one process,
            # needs the child started with CREATE_NEW_PROCESS_GROUP, and would
            # then reach every process in that group. Answering False is the
            # honest report for both.
            if signal != SignalCodes.KILL or self.handle == 0:
                return False
            var ok = external_call["TerminateProcess", Int32](
                self.handle, _STATUS_CONTROL_C_EXIT
            )
            return ok != 0
        else:
            # `kill` returns 0 on success and -1 on failure
            return kill(Int32(self.child_pid), Int32(signal)) > -1

    def _check_status(
        self, pid: c_pid_t, status: c_int
    ) raises -> ProcessStatus:
        """Helper to decode the result of a waitpid call.

        The decoding logic is a direct implementation of the standard C macros
        used to interpret the `status` integer returned by `waitpid`. These
        macros are defined in `<sys/wait.h>` on POSIX systems.

        This implementation is based on the definitions found in `musl` libc.:
        https://git.musl-libc.org/cgit/musl/tree/include/sys/wait.h

        The core logic relies on the following macro definitions:
        - `#define WEXITSTATUS(s) (((s) & 0xff00) >> 8)`
        - `#define WTERMSIG(s)    ((s) & 0x7f)`
        - `#define WIFEXITED(s)   (WTERMSIG(s) == 0)`

        Note on Endianness:
        This logic is endianness-independent. The `waitpid` status is an integer
        value provided by the kernel. All bitwise operations (`&`, `>>`) are
        performed on this integer's numerical value, not its byte representation
        in memory. The result is therefore consistent across architectures.
        """
        if pid == self.child_pid:
            # Process has terminated. Decode the status.
            if (status & 0x7F) == 0:
                # Process exited normally. Extract the exit code.
                var code = (status & 0xFF00) >> 8
                return ProcessStatus(exit_code=Optional(Int(code)))
            else:
                # Process was terminated by a signal. Extract the signal number.
                var signal = status & 0x7F
                return ProcessStatus(term_signal=Optional(Int(signal)))
        elif pid == 0:
            # Process is still running (only for non-blocking calls).
            return ProcessStatus.running()
        else:
            # An error occurred.
            var err = get_errno()
            raise Error("waitpid failed with errno " + String(err))

    def hangup(mut self) -> Bool:
        """Send the Hang up signal to the managed child process.

        Returns:
          Upon successful completion, True is returned else False.
        """
        return self._kill(SignalCodes.HUP)

    def interrupt(mut self) -> Bool:
        """Send the Interrupt signal to the managed child process.

        Returns:
          Upon successful completion, True is returned else False.
        """
        return self._kill(SignalCodes.INT)

    def kill(mut self) -> Bool:
        """Send the Kill signal to the managed child process.

        Returns:
          Upon successful completion, True is returned else False.
        """
        return self._kill(SignalCodes.KILL)

    def poll(mut self) raises -> ProcessStatus:
        """Check if the child process has terminated in a non-blocking way.

        This method updates the internal state of the `Process` object.
        If the process has terminated, the status is cached.

        Returns:
            A `ProcessStatus` indicating the status of the process.

        Raises:
            Error: If `waitpid` fails.
        """
        if self.status:
            return self.status.value()

        var result: ProcessStatus
        comptime if CompilationTarget.is_windows():
            result = _windows_status(self.handle, blocking=False)
        else:
            var status: c_int = 0
            var pid = waitpid(
                self.child_pid, Pointer(to=status), WaitFlags.WNOHANG
            )
            result = self._check_status(pid, status)
        if result.has_exited():
            self.status = result
        return result

    def wait(mut self) raises -> ProcessStatus:
        """Wait for the child process to terminate (blocking).

        This method updates the internal state of the `Process` object.
        If the process has terminated, the status is cached.

        Returns:
          A `ProcessStatus` indicating the process has exited and its status.

        Raises:
            Error: If `waitpid` fails or the process does not exit.
        """
        if self.status:
            return self.status.value()

        var result: ProcessStatus
        comptime if CompilationTarget.is_windows():
            result = _windows_status(self.handle, blocking=True)
        else:
            var status: c_int = 0
            var pid = waitpid(self.child_pid, Pointer(to=status), 0)
            result = self._check_status(pid, status)
        if result.has_exited():
            self.status = result
        else:
            # Not reachable: both arms above were told to wait for the process
            # rather than to look and come back.
            raise Error("Blocking wait returned without process exiting.")
        return result

    @staticmethod
    def run(var path: String, argv: List[String]) raises -> Process:
        """Spawn new process from file executable.

        Args:
          path: The path to the file.
          argv: A list of string arguments to be passed to executable.

        Returns:
          An instance of `Process` struct.

        Raises:
            Error: If the process fails to spawn.
        """

        comptime if CompilationTarget.is_windows():
            return Process(child_pid=0, handle=_windows_spawn(path, argv))
        else:
            comptime assert (
                CompilationTarget.is_linux() or CompilationTarget.is_macos()
            ), "Unknown platform process execution not implemented"
            var parts = path.split(sep)
            var file_name = String(parts[len(parts) - 1])

            var arg_count = len(argv)
            var argv_array_ptr_cstr_ptr = List[
                Optional[CStringSlice[ImmutAnyOrigin]]
            ](
                length=arg_count + 2,
                fill={},
            )
            var offset = 0
            # Arg 0 in `argv` ptr array should be the file name
            argv_array_ptr_cstr_ptr[offset] = rebind[
                CStringSlice[ImmutAnyOrigin]
            ](file_name.as_c_string_slice())
            offset += 1

            for var arg in argv:
                argv_array_ptr_cstr_ptr[offset] = rebind[
                    CStringSlice[ImmutAnyOrigin]
                ](arg.as_c_string_slice())
                offset += 1

            # `argv` ptr array terminates with NULL PTR
            argv_array_ptr_cstr_ptr[offset] = {}

            var pid: c_pid_t = 0

            var has_error_code = posix_spawnp(
                Pointer(to=pid),
                path.as_c_string_slice(),
                # Safety: `argv_array_ptr_cstr_ptr` has at least 2 elements
                # so is non-null
                argv_array_ptr_cstr_ptr.unsafe_ptr(),
                _get_environ(),  # inherit parent's environment
            )

            if has_error_code > 0:
                raise Error(
                    t"Failed to execute {path}, EINT error code:"
                    t" {has_error_code}"
                )

            return Process(child_pid=pid)
