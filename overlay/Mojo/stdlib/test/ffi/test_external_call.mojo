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

import std.os
from std.ffi import CStringSlice, c_char, c_int, external_call
from std.memory import ImmPointer, MutPointer, alloc
from std.os import remove
from std.pathlib import Path
from std.sys import CompilationTarget
from std.sys._libc import FcntlCommands, FcntlFDFlags, fcntl
from std.tempfile import gettempdir
from std.testing import TestSuite, assert_equal, assert_false, assert_true


struct RegisterPassablePointer(RegisterPassable):
    var pointer: OptionalPointer[NoneType, UntrackedOrigin[mut=True]]


def test_external_call_handles_rp_return_types() raises:
    var path = "/does/not/exist/here/file.file"
    var mode = "r"
    var result = external_call["fopen", RegisterPassablePointer](
        path.as_c_string_slice(), mode.as_c_string_slice()
    )
    assert_false(result.pointer)


def test_snprintf_mixed_variadic_args() raises:
    """Formats through a real C variadic callee.

    Every argument after the format string travels the variadic path, which
    AAPCS on ARM64 macOS passes on the stack rather than in registers. Without
    a variadic callee declaration these land in the wrong slots and the
    conversions read unrelated memory.
    """
    comptime SIZE = 64
    var allocation = alloc[c_char]({count = SIZE}).into_managed()
    var buf = allocation.unsafe_ptr()
    var fmt = "[%d|%s|%d|%.2f|%c]".as_c_string_slice()
    var word = "mid".as_c_string_slice()

    var written = external_call["snprintf", c_int, num_fixed_args=3](
        buf,
        Int(SIZE),
        fmt.ptr(),
        c_int(42),
        word.ptr(),
        c_int(-7),
        Float64(2.5),
        c_int(ord("z")),
    )

    var formatted = String(
        StringSlice(unsafe_from_utf8=CStringSlice(unsafe_from_ptr=buf))
    )

    assert_equal(formatted, "[42|mid|-7|2.50|z]")
    assert_equal(Int(written), 18)


def test_open_honors_mode_argument() raises:
    """Checks that `open()`'s variadic mode argument reaches the callee.

    `_open_file` passes mode `0o666` as a variadic argument to `open(2)`. When
    that argument is misplaced the file is created with whatever bits happen to
    be in the register the kernel reads, which used to require an `fchmod()`
    fixup afterwards.
    """
    var path = Path(gettempdir().value()) / "test_external_call_variadic.txt"
    try:
        remove(path)
    except:
        pass

    with open(path, "w") as f:
        f.write("variadic")

    var mode = std.os.stat(path).st_mode
    remove(path)

    # The requested 0o666 is masked by umask, so only assert the bits umask
    # cannot clear for the owner, plus the absence of execute bits.
    assert_equal(mode & 0o600, 0o600)
    assert_equal(mode & 0o111, 0)


@always_inline
def _snprintf_through_pack[
    *types: Intable
](
    buffer: MutPointer[c_char, _],
    size: Int,
    format: ImmPointer[c_char, _],
    *args: *types,
) -> c_int:
    """Calls `snprintf()` with everything after the format string in a pack.

    Shaped exactly like `sys._libc.fcntl`, which is the only other place a
    variadic C function is reached through an argument pack, so that the
    loading the pack needs is covered on a platform that has no `fcntl()`.
    """
    return external_call["snprintf", c_int, num_fixed_args=3](
        buffer, size, format, args.get_loaded_kgen_pack()
    )


def test_argument_pack_forwards_loaded_values() raises:
    """Sends variadic arguments through an argument pack rather than directly.

    A pack reaches the callee as references to its elements unless it is
    loaded first, and a C variadic callee reading references as integers
    prints addresses. `sys._libc.fcntl` is the wrapper this shape exists for
    and the test below covers it, but there is no `fcntl()` on Windows, so
    this covers the same mechanism everywhere.
    """
    comptime SIZE = 32
    var allocation = alloc[c_char]({count = SIZE}).into_managed()
    var buf = allocation.unsafe_ptr()
    var fmt = "[%d|%d|%d]".as_c_string_slice()

    var written = _snprintf_through_pack(
        buf, Int(SIZE), fmt.ptr(), c_int(3), c_int(-14), c_int(159)
    )

    var formatted = String(
        StringSlice(unsafe_from_utf8=CStringSlice(unsafe_from_ptr=buf))
    )

    assert_equal(formatted, "[3|-14|159]")
    assert_equal(Int(written), 11)


def test_fcntl_forwards_variadic_argument() raises:
    """Round-trips a flag through `fcntl()`'s variadic third argument.

    The wrapper takes the flag through an argument pack, which reaches the
    callee as a reference unless the pack is loaded, so this asserts on the
    flag `fcntl()` actually applied rather than on its return value alone.
    """
    comptime if CompilationTarget.is_windows():
        # The Microsoft C runtime has no `fcntl()` under any spelling, and
        # there is no descriptor flag on Windows that the same call would set,
        # so there is nothing to write a Windows arm around. What this covers
        # about argument packs is covered above by a call that works
        # everywhere.
        return

    var path = Path(gettempdir().value()) / "test_external_call_fcntl.txt"
    try:
        remove(path)
    except:
        pass

    with open(path, "w") as f:
        var fd = c_int(f.handle)
        assert_true(
            fcntl(fd, FcntlCommands.F_SETFD, FcntlFDFlags.FD_CLOEXEC) != -1
        )
        var flags = fcntl(fd, FcntlCommands.F_GETFD, 0)
        assert_equal(flags & FcntlFDFlags.FD_CLOEXEC, FcntlFDFlags.FD_CLOEXEC)

    remove(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
