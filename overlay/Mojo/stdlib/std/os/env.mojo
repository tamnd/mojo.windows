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
"""Provides functions for working with environment variables.

You can import these APIs from the `os` package. For example:

```mojo
from std.os import setenv
```
"""

from std.ffi import c_int, external_call
from std.sys import CompilationTarget
from std.sys._win import to_utf16, to_utf8

# ===-----------------------------------------------------------------------===#
# Windows
# ===-----------------------------------------------------------------------===#

# Every function below goes through Win32 on Windows rather than through the C
# runtime, and the reason is that on Windows there is no such thing as the C
# runtime, singular. Each module in a Mojo program links its own copy, and a
# program here is at least an executable and three libraries, so `getenv` and
# `_putenv_s` answer about whichever copy the caller happened to be compiled
# into. Each copy takes a snapshot of the process environment when it starts
# and does not look at it again, so a variable set by another module, or by
# Win32 directly, is invisible. That is not a corner case: the Python library
# path is found by C++ in `KGENCompilerRTShared.dll` and read by Mojo in the
# executable, and before this it was never seen.
#
# The process environment block that `GetEnvironmentVariableW` reads is the one
# thing all of them agree about. It is what every runtime copy was built from,
# it is what a child process inherits, and it is the same answer whichever
# module is asking. So these read and write that, and the runtime copies are
# left to be somebody else's problem.
#
# Wide rather than narrow, because the narrow forms encode in the active code
# page and mangle anything it cannot spell, and a path with a name in it is not
# unusual.

comptime _ENV_CHARS = 256


def _win_getenv(name: String) -> Optional[String]:
    """The value in the process environment, if it has one."""
    var wide_name = to_utf16(name.as_bytes(), is_path=False)
    var buffer = List[UInt16](length=_ENV_CHARS, fill=0)
    var count = Int(
        external_call["GetEnvironmentVariableW", UInt32](
            wide_name.unsafe_ptr(), buffer.unsafe_ptr(), UInt32(_ENV_CHARS)
        )
    )

    # A count that reaches the end of the buffer means it did not fit, and the
    # number is then what it would take including the nul. Same two step shape
    # as every other sized Win32 call.
    if count >= _ENV_CHARS:
        buffer = List[UInt16](length=count, fill=0)
        count = Int(
            external_call["GetEnvironmentVariableW", UInt32](
                wide_name.unsafe_ptr(), buffer.unsafe_ptr(), UInt32(count)
            )
        )
    _ = wide_name^

    # Zero is the only failure this reports, and the only reason it fails in
    # practice is that the variable is not set.
    if count == 0:
        return None
    var value = to_utf8(Span(unsafe_ptr=buffer.unsafe_ptr(), length=count))
    _ = buffer^
    return value^


def _win_putenv(name: String, value: String) -> Bool:
    """Sets a variable in the process environment, or removes it if empty.

    Windows has no way to hold a variable with an empty value, so setting one
    to nothing and removing it are the same operation, which is what the C
    runtime's `_putenv_s` documents too.
    """
    # Win32 does not object to either of these the way `setenv` does, and one
    # of them it positively likes: a name beginning with `=` is how it hides
    # the per drive current directory, so `SetEnvironmentVariableW` takes `=`
    # for a name and reports success. The answer these functions document is
    # False, so the two cases are checked here rather than left to Windows.
    if name.byte_length() == 0 or name.find("=") >= 0:
        return False

    var wide_name = to_utf16(name.as_bytes(), is_path=False)
    var wide_value = to_utf16(value.as_bytes(), is_path=False)
    var status = external_call["SetEnvironmentVariableW", c_int](
        wide_name.unsafe_ptr(), wide_value.unsafe_ptr()
    )
    _ = wide_name^
    _ = wide_value^
    return status != 0


def setenv(var name: String, var value: String, overwrite: Bool = True) -> Bool:
    """Changes or adds an environment variable.

    Args:
      name: The name of the environment variable.
      value: The value of the environment variable.
      overwrite: If an environment variable with the given name already exists,
        its value is not changed unless `overwrite` is True.

    Returns:
      False if the name is empty or contains an `=` character. In any other
      case, True is returned.
    """
    comptime if CompilationTarget.is_windows():
        # Windows has no overwrite flag on any of its ways of doing this, so
        # the existing value is read first. That read and the write are two
        # separate calls, which does not matter here: the environment belongs
        # to this process and nothing else is competing to write it.
        if not overwrite and _win_getenv(name):
            return True
        return _win_putenv(name, value)

    var status = external_call["setenv", Int32](
        name.as_c_string_slice(),
        value.as_c_string_slice(),
        Int32(1 if overwrite else 0),
    )
    return status == 0


def unsetenv(var name: String) -> Bool:
    """Unsets an environment variable.

    Args:
        name: The name of the environment variable.

    Returns:
        True if unsetting the variable succeeded. Otherwise, False is returned.
    """
    comptime if CompilationTarget.is_windows():
        # Windows has no `unsetenv` either. Assigning an empty value is how it
        # removes a variable, and a read afterwards reports it as missing
        # rather than as empty, so this is a removal and not a blanking.
        return _win_putenv(name, String())

    return external_call["unsetenv", c_int](name.as_c_string_slice()) == 0


def getenv(var name: String, default: String = "") -> String:
    """Returns the value of the given environment variable.

    Args:
      name: The name of the environment variable.
      default: The default value to return if the environment variable
        doesn't exist.

    Returns:
      The value of the environment variable.
    """
    comptime if CompilationTarget.is_windows():
        return _win_getenv(name).or_else(default.copy())

    var ptr = external_call[
        "getenv", OptionalPointer[UInt8, ImmUntrackedOrigin]
    ](name.as_c_string_slice())
    if not ptr:
        return default
    return String(unsafe_from_utf8_ptr=ptr.value())
