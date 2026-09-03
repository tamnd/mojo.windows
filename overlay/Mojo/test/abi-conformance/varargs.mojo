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
"""Calls where the callee cannot see the signature.

Everywhere else in this suite the callee's parameter list says what to expect.
Here it does not, and the two conventions handle that in opposite ways.

Win64 hardly changes. Arguments keep their positions, and the one extra rule is
that a floating point variadic argument goes in the SSE register and in the
integer register sharing its slot, because the callee walking a `va_list` reads
the integer one and has no way to know it should have looked elsewhere.

System V changes a lot. The callee spills the argument registers into a save
area so `va_arg` can walk them, and it decides how many SSE registers to spill
by reading AL, which the caller has to set to the number of vector registers it
used. A caller that ignores AL is not passing a wrong number, it is telling the
callee to spill a count left over from whatever ran before. That failure is not
deterministic, which makes it the worst one in this area to debug and the best
one to have a test for.

What this file does not do, which I expected it to, is catch a wrong C `long`.
A variadic slot on x86-64 is eight bytes like a fixed one, in both conventions,
so `va_arg` advances a whole slot whether `long` is four bytes or eight and the
width is absorbed here the same way it is everywhere else. Measured rather than
reasoned about: building this with `c_long` set to 64 bits on Windows still
passes. The `long` case stays because that is a fact about x86-64 and not about
varargs, and AAPCS on arm64 sizes a variadic slot by the type.

Prints nothing when everything passes and exits zero. Prints one line per
failure and exits one otherwise.
"""

from std.ffi import c_long, external_call
from std.sys import exit

from abi_probe import (
    check_count,
    check_float,
    check_int,
    check_returned_int,
    reset,
)


def int_at(index: Int) -> Int64:
    """A distinct value per position, small enough to survive a 32 bit `long`."""
    return Int64(500 + index * 11)


def float_at(index: Int) -> Float64:
    """The same idea for the floating point positions."""
    return Float64(index * 6 + 1) + 0.5


def test_ints() -> Int:
    """Six variadic integers, no floats anywhere, so AL should be zero."""
    reset()
    external_call["abi_va_ints", NoneType, num_fixed_args=1](
        Int32(6),
        int_at(0),
        int_at(1),
        int_at(2),
        int_at(3),
        int_at(4),
        int_at(5),
    )
    var failures = check_count("abi_va_ints", 6)
    for index in range(6):
        failures += check_int("abi_va_ints", index, int_at(index))
    return failures


def test_doubles() -> Int:
    """Six variadic doubles, which is what AL is there to count."""
    reset()
    external_call["abi_va_doubles", NoneType, num_fixed_args=1](
        Int32(6),
        float_at(0),
        float_at(1),
        float_at(2),
        float_at(3),
        float_at(4),
        float_at(5),
    )
    var failures = check_count("abi_va_doubles", 6)
    for index in range(6):
        failures += check_float("abi_va_doubles", index, float_at(index))
    return failures


def test_mixed() -> Int:
    """Alternating, starting with an integer.

    Both rules are live at once here. The doubles need to go into two registers
    on Windows and they are what AL counts on Linux, and the integers between
    them are what shows if either of those pushed the list out of step.
    """
    reset()
    external_call["abi_va_mixed", NoneType, num_fixed_args=1](
        Int32(6),
        int_at(0),
        float_at(1),
        int_at(2),
        float_at(3),
        int_at(4),
        float_at(5),
    )
    var failures = check_count("abi_va_mixed", 6)
    for index in range(6):
        if index % 2 == 0:
            failures += check_int("abi_va_mixed", index, int_at(index))
        else:
            failures += check_float("abi_va_mixed", index, float_at(index))
    return failures


def test_all_doubles() -> Int:
    """Eight doubles, enough to use every SSE register either convention gives
    out, which is where a wrong AL does the most damage.
    """
    reset()
    external_call["abi_va_all_doubles", NoneType, num_fixed_args=1](
        Int32(8),
        float_at(0),
        float_at(1),
        float_at(2),
        float_at(3),
        float_at(4),
        float_at(5),
        float_at(6),
        float_at(7),
    )
    var failures = check_count("abi_va_all_doubles", 8)
    for index in range(8):
        failures += check_float("abi_va_all_doubles", index, float_at(index))
    return failures


def test_many() -> Int:
    """Twelve, so the list runs past the register save area onto the stack.

    The seam between the saved registers and the caller's stack is somewhere a
    caller can be wrong without being wrong about anything else, and it is only
    reachable by passing more arguments than the registers hold.
    """
    reset()
    external_call["abi_va_many", NoneType, num_fixed_args=1](
        Int32(12),
        int_at(0),
        int_at(1),
        int_at(2),
        int_at(3),
        int_at(4),
        int_at(5),
        int_at(6),
        int_at(7),
        int_at(8),
        int_at(9),
        int_at(10),
        int_at(11),
    )
    var failures = check_count("abi_va_many", 12)
    for index in range(12):
        failures += check_int("abi_va_many", index, int_at(index))
    return failures


def test_promotions() -> Int:
    """The default argument promotions, which are the caller's job.

    Anything narrower than an int becomes an int and a float becomes a double,
    before the call, because the callee cannot ask for anything narrower than
    that. A caller that passes a `Float32` unpromoted leaves the callee reading
    eight bytes where four were written.
    """
    reset()
    external_call["abi_va_promoted", NoneType, num_fixed_args=1](
        Int32(4),
        Int32(int_at(0)),
        Float64(Float32(float_at(1))),
        Int32(int_at(2)),
        Float64(Float32(float_at(3))),
    )
    var failures = check_count("abi_va_promoted", 4)
    failures += check_int("abi_va_promoted", 0, int_at(0))
    failures += check_float(
        "abi_va_promoted", 1, Float64(Float32(float_at(1)))
    )
    failures += check_int("abi_va_promoted", 2, int_at(2))
    failures += check_float(
        "abi_va_promoted", 3, Float64(Float32(float_at(3)))
    )
    return failures


def test_longs() -> Int:
    """C `long` through a `va_list`.

    Written to be the one place a wrong width produces a wrong value, and it is
    not. A variadic slot on x86-64 is eight bytes like any other, so `va_arg`
    steps over a whole one and a 64 bit `long` on Windows passes this test. The
    case is kept because it is the one that starts failing on arm64, where a
    variadic slot is sized by the type it holds.
    """
    reset()
    external_call["abi_va_longs", NoneType, num_fixed_args=1](
        Int32(5),
        c_long(int_at(0)),
        c_long(int_at(1)),
        c_long(int_at(2)),
        c_long(int_at(3)),
        c_long(int_at(4)),
    )
    var failures = check_count("abi_va_longs", 5)
    for index in range(5):
        failures += check_int("abi_va_longs", index, int_at(index))
    return failures


def test_return() -> Int:
    """A variadic call that returns something, since none of the above do."""
    var want = int_at(0) + int_at(1) + int_at(2)
    var got = external_call["abi_va_sum", Int64, num_fixed_args=1](
        Int32(3), int_at(0), int_at(1), int_at(2)
    )
    return check_returned_int("abi_va_sum", got, want)


def test_snprintf() -> Int:
    """The platform's own variadic function, which is the case that has to work.

    Every probe above was written in the same file as the rest of this test and
    compiled with the same assumptions. `snprintf` shares neither, and it is
    also what real code reaches for, so a suite that only ever calls its own
    probes has not proved the thing anyone cares about.

    The format takes an int, a long long, a double and a string, so the call
    mixes register classes and the promotions in one place. C makes the same
    call into a buffer of its own and compares, rather than this comparing
    against a literal, because how a platform renders a double is not what is
    being tested here.
    """
    external_call["abi_text_clear", NoneType]()
    var buffer = external_call["abi_text_buffer", Int64]()
    var size = external_call["abi_text_size", Int32]()
    var format = external_call["abi_text_format", Int64]()
    var argument = external_call["abi_text_argument", Int64]()

    var written = external_call["snprintf", Int32, num_fixed_args=3](
        buffer,
        Int64(size),
        format,
        Int32(42),
        Int64(1234567890123),
        Float64(2.5),
        argument,
    )
    if written <= 0:
        print("FAIL snprintf wrote", written, "bytes")
        return 1

    if external_call["abi_text_matches_reference", Int32]() == 1:
        return 0

    print("FAIL snprintf through external_call did not match C. Mojo produced:")
    var text = String()
    for index in range(Int(written)):
        var byte = external_call["abi_text_byte", Int32](Int32(index))
        if byte <= 0:
            break
        text += chr(Int(byte))
    print(text)
    return 1


def main():
    var failures = test_ints()
    failures += test_doubles()
    failures += test_mixed()
    failures += test_all_doubles()
    failures += test_many()
    failures += test_promotions()
    failures += test_longs()
    failures += test_return()
    failures += test_snprintf()

    if failures != 0:
        print(failures, "checks failed")
        exit(1)

    print("varargs ABI conformance passed")
