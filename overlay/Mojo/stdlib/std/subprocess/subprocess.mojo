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
"""Provides utilities for executing shell commands and capturing output.

This module offers functions for running shell commands in subprocesses and
retrieving their output, similar to Python's `subprocess` module. It handles
process creation, output capture, and resource cleanup automatically.

Windows has the same idea and spells two of the three names it needs with an
underscore in front. `_popen` runs the command under `cmd.exe /c` the way
`popen` runs it under `/bin/sh -c`, and `_pclose` waits for it to finish. The
third name, `getline`, is POSIX and has no Windows equivalent at all, so the
read below is done with `fread`, which is C89 and needs no arm of its own.
Losing `getline` is no loss: a line at a time was never what this wanted, since
the lines were being joined straight back together.

The stream is opened in binary mode on Windows, so a child that writes CRLF
line endings gets them back unchanged instead of having them quietly turned
into newlines. That matches every other file this library opens, and it is the
only choice that also works for a command whose output is not text.
"""

from std.ffi import c_int, c_size_t, external_call
from std.sys._libc import FILE_ptr, pclose, popen
from std.sys.info import CompilationTarget

from std.collections import List, Span

# How much is asked for per `fread`. A pipe holds 64 KiB and most commands say
# far less than that, so this is about not calling into the runtime once per
# handful of bytes rather than about matching any buffer anywhere.
comptime _CHUNK_BYTES = 4096


def _command_open(mut cmd: String, mut mode: String) -> FILE_ptr:
    """Starts `cmd` under the system command interpreter, joined by a pipe.

    Both strings are taken mutably because `as_c_string_slice` is what puts the
    terminating zero on the end, and it can only do that to a string it is
    allowed to write to.
    """

    comptime if CompilationTarget.is_windows():
        # The CRT's own name for it, and the extra letter that asks for the
        # bytes the child wrote rather than a rewritten copy of them.
        var win_mode = mode + "b"
        var handle = external_call["_popen", FILE_ptr](
            cmd.as_c_string_slice(), win_mode.as_c_string_slice()
        )
        _ = win_mode^
        return handle
    else:
        return popen(cmd.as_c_string_slice(), mode.as_c_string_slice())


def _command_close(stream: FILE_ptr) -> c_int:
    """Waits for the command started by `_command_open` and closes the pipe."""

    comptime if CompilationTarget.is_windows():
        return external_call["_pclose", c_int](stream)
    else:
        return pclose(stream)


struct _POpenHandle:
    """Handle to an open file descriptor opened via popen."""

    var _handle: FILE_ptr

    def __init__(out self, var cmd: String, var mode: String = "r") raises:
        """Construct the _POpenHandle using the command and mode provided.

        Args:
          cmd: The command to open.
          mode: The mode to open the file in (the mode can be "r" or "w").
        """
        if mode != "r" and mode != "w":
            raise Error("the mode specified `", mode, "` is not valid")

        self._handle = _command_open(cmd, mode)

        if not self._handle:
            raise Error("unable to execute the command `", cmd, "`")

    def __deinit__(deinit self):
        """Closes the handle opened via popen."""
        _ = _command_close(self._handle)

    def read(self) raises -> String:
        """Reads all the data from the handle.

        Returns:
            A string containing the output of running the command.

        Raises:
            This method raises if:
            * There is an IO error reading from the subprocess.
            * The data written by the subprocess is not valid UTF-8.
        """
        var bytes = List[Byte]()
        var chunk = Array[Byte, _CHUNK_BYTES](fill=0)

        while True:
            var read = Int(
                external_call["fread", c_size_t](
                    chunk.unsafe_ptr(),
                    c_size_t(1),
                    c_size_t(_CHUNK_BYTES),
                    self._handle,
                )
            )
            if read > 0:
                bytes.extend(Span(chunk)[:read])
            # A short read means the end of the stream or an error, and the two
            # are told apart below rather than here, because either way there is
            # nothing left to ask for.
            if read < _CHUNK_BYTES:
                break

        if external_call["ferror", c_int](self._handle) != 0:
            raise Error("error reading the output of the command")

        # Note: This will raise if the subprocess yields non-UTF-8 bytes.
        var res = String(from_utf8=Span(bytes))
        return String(res.rstrip())


def run(cmd: String) raises -> String:
    """Runs the specified command and returns the output as a string.

    This function executes the given command in a subprocess, captures its
    standard output, and returns it as a string. It automatically handles
    opening and closing the subprocess.

    Args:
        cmd: The command to execute as a string.

    Returns:
        The standard output of the command as a string, with trailing
        whitespace removed.

    Raises:
        This function raises if:
        * The command cannot be executed.
        * There is an IO error reading from the subprocess.
        * The data written by the subprocess is not valid UTF-8.
    """
    var hdl = _POpenHandle(cmd)
    return hdl.read()
