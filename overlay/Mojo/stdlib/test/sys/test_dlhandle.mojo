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

from std.pathlib import Path
from std.ffi import OwnedDLHandle

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_raises, assert_true
from std.testing import TestSuite


comptime _GETPID = "_getpid" if CompilationTarget.is_windows() else "getpid"
"""The C library's own process id call, which Windows spells with an
underscore because the name without one is not in any C standard."""


def _load_libc() raises -> OwnedDLHandle:
    """Loads libc from the standard location for this platform.

    Selects platform-appropriate paths up front so that a failure on
    (say) Linux doesn't propagate a confusing macOS-path error message.
    """
    comptime if CompilationTarget.is_linux():
        try:
            return OwnedDLHandle("libc.so.6")  # glibc
        except:
            pass
        return OwnedDLHandle("libc.so")  # musl / BSD
    elif CompilationTarget.is_macos():
        return OwnedDLHandle("/usr/lib/system/libsystem_c.dylib")
    elif CompilationTarget.is_windows():
        # The universal C runtime, which every supported Windows has in
        # system32. By name and not by path on purpose, so that the loader
        # applies its own search order and finds the one the process is already
        # using rather than a second copy.
        return OwnedDLHandle("ucrtbase.dll")
    else:
        comptime assert False, "libc discovery not implemented for platform"


def _load_libm() raises -> OwnedDLHandle:
    """Loads libm (math functions) from the standard location for this
    platform.

    On glibc, math lives in libm.so.6. Everywhere else math is folded into the
    C library, so we fall back to `_load_libc` there.
    """
    comptime if CompilationTarget.is_linux():
        try:
            return OwnedDLHandle("libm.so.6")  # glibc
        except:
            pass
        # musl folds math into libc.
        return _load_libc()
    else:
        # macOS has them in libSystem and Windows has them in the universal C
        # runtime, and in both cases that is the handle `_load_libc` returns.
        return _load_libc()


# ===----------------------------------------------------------------------=== #
# OwnedDLHandle tests
# ===----------------------------------------------------------------------=== #


def test_owned_dlhandle_invalid_path() raises:
    with assert_raises(contains="dlopen failed"):
        _ = OwnedDLHandle("/an/invalid/library")


def test_owned_dlhandle_invalid_path_obj() raises:
    with assert_raises(contains="dlopen failed"):
        _ = OwnedDLHandle(Path("/an/invalid/library"))


def test_owned_dlhandle_load_valid_library() raises:
    var lib = _load_libc()
    assert_true(lib.__bool__(), "Library handle should be valid")


def test_owned_dlhandle_check_symbol() raises:
    var lib = _load_libc()
    # Functions the C library has everywhere. Not `printf`, which is in glibc
    # and in libSystem but is not an exported symbol of the universal C
    # runtime, because Windows resolves it through an inline in stdio.h.
    assert_true(lib.check_symbol("malloc"), "malloc should exist in libc")
    assert_true(lib.check_symbol("free"), "free should exist in libc")


def test_owned_dlhandle_borrow() raises:
    """Test that borrow() returns a valid DLHandle reference."""
    var lib = _load_libc()
    var borrowed = lib.borrow()
    # borrowed should be a valid DLHandle
    assert_true(borrowed.__bool__(), "Borrowed handle should be valid")
    assert_true(
        borrowed.check_symbol("malloc"),
        "Borrowed handle should access symbols",
    )


def test_owned_dlhandle_global_symbols() raises:
    """Test loading global symbols from current process."""
    # On POSIX this is `dlopen(NULL)` and reaches every symbol the process has
    # loaded. On Windows it is the handle of the executable itself, which
    # reaches what the executable exports and nothing else, because the Windows
    # loader has no flat namespace to ask. Both give a usable handle, which is
    # all this asserts, and the difference is documented in `sys/_dl.mojo`.
    var lib = OwnedDLHandle()
    assert_true(lib.__bool__(), "Global symbol handle should be valid")


def test_owned_dlhandle_get_symbol_missing() raises:
    """Test that get_symbol returns None for a nonexistent symbol."""
    var lib = _load_libc()
    var result = lib.get_symbol[NoneType]("this_symbol_does_not_exist_xyz_42")
    assert_true(not result, "Missing symbol should return None")


def test_owned_dlhandle_get_symbol_found() raises:
    """Test that get_symbol returns a value for an existing symbol."""
    var lib = _load_libc()
    var result = lib.get_symbol[NoneType]("malloc")
    assert_true(Bool(result), "Existing symbol should return a value")


def test_owned_dlhandle_get_function_keepalive() raises:
    """Inline resolve and call with no later use of the handle."""
    var lib = _load_libc()
    # Inline resolve + call, no subsequent use of `lib`.
    var pid = lib.get_function[Int32](_GETPID)()
    assert_true(pid > 0, "getpid should return a positive pid")


def test_owned_dlhandle_get_function_stored_callable() raises:
    var lib = _load_libc()
    var getpid_fn = lib.get_function[Int32](_GETPID)
    assert_true(getpid_fn() > 0, "call 1")
    assert_true(getpid_fn() > 0, "call 2")
    assert_true(getpid_fn() > 0, "call 3")


def test_owned_dlhandle_get_function_multiple_inline_calls() raises:
    """Resolves and calls the same symbol inline, without binding the returned
    callable to a variable."""
    var lib = _load_libc()
    _ = lib.get_function[Int32](_GETPID)()
    _ = lib.get_function[Int32](_GETPID)()
    _ = lib.get_function[Int32](_GETPID)()
    _ = lib.get_function[Int32](_GETPID)()


def test_owned_dlhandle_get_function_with_args() raises:
    """Exercises the variadic argument-forwarding path with a scalar-in,
    scalar-out function through the C ABI."""
    var lib = _load_libc()
    var abs_fn = lib.get_function[Int32]("abs")
    assert_equal(abs_fn(Int32(-5)), Int32(5), "abs(-5) should return 5")
    assert_equal(abs_fn(Int32(42)), Int32(42), "abs(42) should return 42")
    assert_equal(abs_fn(Int32(0)), Int32(0), "abs(0) should return 0")


def test_owned_dlhandle_get_function_multiple_args() raises:
    """Exercises forwarding of more than one argument. A single argument does
    not distinguish per-argument lowering from a one-element pack."""
    var lib = _load_libm()
    var pow_fn = lib.get_function[Float64]("pow")
    assert_equal(pow_fn(Float64(2.0), Float64(10.0)), Float64(1024.0), "2^10")
    assert_equal(pow_fn(Float64(2.0), Float64(-2.0)), Float64(0.25), "2^-2")


def test_owned_dlhandle_get_function_missing_symbol_raises() raises:
    """A missing symbol raises `Error`, so callers that probe for optional
    symbols can recover."""
    var lib = _load_libc()
    with assert_raises(contains="symbol not found"):
        _ = lib.get_function[Int32]("this_symbol_does_not_exist_xyz_42")


def test_owned_dlhandle_get_function_float64_return() raises:
    """Exercises the `Float64` return-type path to match the docstring
    example and ensure non-`Int32` scalars round-trip through the C-ABI
    forwarding correctly."""
    var lib = _load_libm()
    var sqrt_fn = lib.get_function[Float64]("sqrt")
    assert_equal(sqrt_fn(Float64(4.0)), Float64(2.0), "sqrt(4.0)")
    assert_equal(sqrt_fn(Float64(0.0)), Float64(0.0), "sqrt(0.0)")
    assert_equal(sqrt_fn(Float64(1.0)), Float64(1.0), "sqrt(1.0)")


def test_owned_dlhandle_get_function_default_return_type() raises:
    """Exercises the default `NoneType` return type (omitted type param)
    against a void-returning libc function. `srand(unsigned)` takes a
    scalar and returns void."""
    var lib = _load_libc()
    var srand_fn = lib.get_function("srand")
    srand_fn(UInt32(42))
    srand_fn(UInt32(0))


def test_owned_dlhandle_get_function_explicit_nonetype_return() raises:
    """Same as the default-return-type test, but with `NoneType` stated
    explicitly — covers the shape used by `TVMFFIErrorMoveFromRaised`
    call sites."""
    var lib = _load_libc()
    var srand_fn = lib.get_function[NoneType]("srand")
    srand_fn(UInt32(7))


def test_owned_dlhandle_get_function_pointer_arg() raises:
    """Exercises a pointer argument through the C ABI: `atoi(const char*)`.
    A pointer is a scalar-class argument, distinct from the integer and float
    scalars covered elsewhere."""
    var lib = _load_libc()
    var atoi_fn = lib.get_function[Int32]("atoi")
    var s = String("123")
    assert_equal(atoi_fn(s.as_c_string_slice()), Int32(123), "atoi(123)")
    var s2 = String("-42")
    assert_equal(atoi_fn(s2.as_c_string_slice()), Int32(-42), "atoi(-42)")


@fieldwise_init
struct _DivT(TrivialRegisterPassable):
    """Matches C `div_t` = `{ int quot; int rem; }`."""

    var quot: Int32
    var rem: Int32


def test_owned_dlhandle_get_function_struct_return() raises:
    """Returns an aggregate by value through the C ABI:
    `div(int, int) -> div_t`."""
    var lib = _load_libc()
    var div_fn = lib.get_function[_DivT]("div")
    var r = div_fn(Int32(17), Int32(5))
    assert_equal(r.quot, Int32(3), "17 / 5 quot")
    assert_equal(r.rem, Int32(2), "17 % 5 rem")
    var r2 = div_fn(Int32(-17), Int32(5))
    assert_equal(r2.quot, Int32(-3), "-17 / 5 quot")
    assert_equal(r2.rem, Int32(-2), "-17 % 5 rem")


@fieldwise_init
struct _CDouble(TrivialRegisterPassable):
    """Same by-value ABI as C `double _Complex`: a homogeneous `{f64, f64}`
    aggregate (SSE-pair on x86-64, HFA-2 on ARM64)."""

    var re: Float64
    var im: Float64


def test_owned_dlhandle_get_function_struct_arg() raises:
    """Passes an aggregate by value through the C ABI:
    `cabs(double _Complex)`."""
    var lib = _load_libm()
    var cabs_fn = lib.get_function[Float64]("cabs")
    assert_equal(cabs_fn(_CDouble(3.0, 4.0)), Float64(5.0), "cabs(3+4i)")
    assert_equal(cabs_fn(_CDouble(5.0, 12.0)), Float64(13.0), "cabs(5+12i)")


def test_owned_dlhandle_call_struct_by_value() raises:
    """Passes and returns an aggregate by value through `OwnedDLHandle.call`,
    the other public entry point to the same forwarding."""
    var libm = _load_libm()
    assert_equal(
        libm.call["cabs", Float64](_CDouble(3.0, 4.0)),
        Float64(5.0),
        "call cabs(3+4i)",
    )
    var libc = _load_libc()
    var r = libc.call["div", _DivT](Int32(17), Int32(5))
    assert_equal(r.quot, Int32(3), "call div quot")
    assert_equal(r.rem, Int32(2), "call div rem")


def test_owned_dlhandle_automatic_cleanup() raises:
    # This test primarily verifies that the code compiles and runs
    # without crashes. The actual cleanup happens automatically.

    @always_inline
    def create_and_destroy_handle() raises:
        var lib = _load_libc()
        _ = lib.check_symbol("malloc")
        # lib will be automatically closed here when it goes out of scope

    # Call the function multiple times to ensure cleanup works
    create_and_destroy_handle()
    create_and_destroy_handle()
    create_and_destroy_handle()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
