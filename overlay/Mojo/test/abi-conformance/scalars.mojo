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
"""Scalar arguments and scalar returns across the C boundary.

Each case calls a probe in probe.c, which was compiled by the platform C
compiler and therefore follows the platform ABI by definition, and then asks the
probe what it actually received. Anything that comes back different is a bug in
how the Mojo compiler lowered the call.

Prints nothing when everything passes and exits zero. Prints one line per
failure and exits one otherwise, so the exit code is the test result and the
output is the diagnosis.
"""

from std.ffi import external_call
from std.sys import exit

from abi_probe import (
    check_count,
    check_float,
    check_int,
    check_returned_float,
    check_returned_int,
    reset,
)


# Distinct per position, so an argument that lands one register off is caught
# rather than matching the value that was supposed to be there.
def int_at(index: Int) -> Int64:
    return Int64(1000 + index * 7)


def float_at(index: Int) -> Float64:
    return Float64(index * 8 + 3) + 0.25


# ===-----------------------------------------------------------------------===#
# Integer scalars at each width
# ===-----------------------------------------------------------------------===#


def test_int8() -> Int:
    comptime probe = "abi_int8_x6"
    reset()
    external_call["abi_int8_x6", NoneType](
        Int8(11), Int8(-22), Int8(33), Int8(-44), Int8(55), Int8(-66)
    )
    var failures = check_count(probe, 6)
    failures += check_int(probe, 0, 11)
    failures += check_int(probe, 1, -22)
    failures += check_int(probe, 2, 33)
    failures += check_int(probe, 3, -44)
    failures += check_int(probe, 4, 55)
    failures += check_int(probe, 5, -66)
    return failures


def test_int16() -> Int:
    comptime probe = "abi_int16_x6"
    reset()
    external_call["abi_int16_x6", NoneType](
        Int16(1111),
        Int16(-2222),
        Int16(3333),
        Int16(-4444),
        Int16(5555),
        Int16(-6666),
    )
    var failures = check_count(probe, 6)
    failures += check_int(probe, 0, 1111)
    failures += check_int(probe, 1, -2222)
    failures += check_int(probe, 2, 3333)
    failures += check_int(probe, 3, -4444)
    failures += check_int(probe, 4, 5555)
    failures += check_int(probe, 5, -6666)
    return failures


def test_int32() -> Int:
    comptime probe = "abi_int32_x6"
    reset()
    external_call["abi_int32_x6", NoneType](
        Int32(111111),
        Int32(-222222),
        Int32(333333),
        Int32(-444444),
        Int32(555555),
        Int32(-666666),
    )
    var failures = check_count(probe, 6)
    failures += check_int(probe, 0, 111111)
    failures += check_int(probe, 1, -222222)
    failures += check_int(probe, 2, 333333)
    failures += check_int(probe, 3, -444444)
    failures += check_int(probe, 4, 555555)
    failures += check_int(probe, 5, -666666)
    return failures


def test_int64() -> Int:
    comptime probe = "abi_int64_x6"
    reset()
    external_call["abi_int64_x6", NoneType](
        Int64(1111111111111),
        Int64(-2222222222222),
        Int64(3333333333333),
        Int64(-4444444444444),
        Int64(5555555555555),
        Int64(-6666666666666),
    )
    var failures = check_count(probe, 6)
    failures += check_int(probe, 0, 1111111111111)
    failures += check_int(probe, 1, -2222222222222)
    failures += check_int(probe, 2, 3333333333333)
    failures += check_int(probe, 3, -4444444444444)
    failures += check_int(probe, 4, 5555555555555)
    failures += check_int(probe, 5, -6666666666666)
    return failures


# ===-----------------------------------------------------------------------===#
# Floating point scalars at each width
# ===-----------------------------------------------------------------------===#


def test_float32() -> Int:
    comptime probe = "abi_float32_x6"
    reset()
    external_call["abi_float32_x6", NoneType](
        Float32(1.5),
        Float32(-2.5),
        Float32(3.25),
        Float32(-4.75),
        Float32(5.125),
        Float32(-6.625),
    )
    var failures = check_count(probe, 6)
    failures += check_float(probe, 0, 1.5)
    failures += check_float(probe, 1, -2.5)
    failures += check_float(probe, 2, 3.25)
    failures += check_float(probe, 3, -4.75)
    failures += check_float(probe, 4, 5.125)
    failures += check_float(probe, 5, -6.625)
    return failures


def test_float64() -> Int:
    comptime probe = "abi_float64_x6"
    reset()
    external_call["abi_float64_x6", NoneType](
        Float64(10.5),
        Float64(-20.25),
        Float64(30.125),
        Float64(-40.0625),
        Float64(50.03125),
        Float64(-60.015625),
    )
    var failures = check_count(probe, 6)
    failures += check_float(probe, 0, 10.5)
    failures += check_float(probe, 1, -20.25)
    failures += check_float(probe, 2, 30.125)
    failures += check_float(probe, 3, -40.0625)
    failures += check_float(probe, 4, 50.03125)
    failures += check_float(probe, 5, -60.015625)
    return failures


# ===-----------------------------------------------------------------------===#
# One argument of the other class, at each of the six positions
# ===-----------------------------------------------------------------------===#
#
# The highest yield family in the suite, and the reason the suite exists. Win64
# numbers the integer and SSE register files together, so a double in position
# three takes XMM2 and leaves RDX unused. System V numbers them separately, so
# the same double takes XMM0 and the integers stay packed into RDI, RSI and RDX.
# A compiler that gets this wrong reads every argument after the first one of
# the minority class out of the wrong register, and says nothing.


# The one float among integers, or the one integer among floats, is checked by
# whichever of these the position calls for, so both directions share a checker.
def check_odd_one_out(probe: StaticString, odd: Int, odd_is_float: Bool) -> Int:
    var failures = check_count(probe, 6)
    for index in range(6):
        # One argument is a float among integers, or an integer among floats.
        # Either way the odd one out is one class and the rest are the other,
        # so knowing which position is odd and which class it is decides every
        # position.
        var is_float = odd_is_float
        if index != odd:
            is_float = not odd_is_float
        if is_float:
            failures += check_float(probe, index, float_at(index))
        else:
            failures += check_int(probe, index, int_at(index))
    return failures


def test_float64_positions() -> Int:
    var failures = 0

    reset()
    external_call["abi_float64_at1", NoneType](
        float_at(0), int_at(1), int_at(2), int_at(3), int_at(4), int_at(5)
    )
    failures += check_odd_one_out("abi_float64_at1", 0, True)

    reset()
    external_call["abi_float64_at2", NoneType](
        int_at(0), float_at(1), int_at(2), int_at(3), int_at(4), int_at(5)
    )
    failures += check_odd_one_out("abi_float64_at2", 1, True)

    reset()
    external_call["abi_float64_at3", NoneType](
        int_at(0), int_at(1), float_at(2), int_at(3), int_at(4), int_at(5)
    )
    failures += check_odd_one_out("abi_float64_at3", 2, True)

    reset()
    external_call["abi_float64_at4", NoneType](
        int_at(0), int_at(1), int_at(2), float_at(3), int_at(4), int_at(5)
    )
    failures += check_odd_one_out("abi_float64_at4", 3, True)

    reset()
    external_call["abi_float64_at5", NoneType](
        int_at(0), int_at(1), int_at(2), int_at(3), float_at(4), int_at(5)
    )
    failures += check_odd_one_out("abi_float64_at5", 4, True)

    reset()
    external_call["abi_float64_at6", NoneType](
        int_at(0), int_at(1), int_at(2), int_at(3), int_at(4), float_at(5)
    )
    failures += check_odd_one_out("abi_float64_at6", 5, True)

    return failures


def test_int64_positions() -> Int:
    var failures = 0

    reset()
    external_call["abi_int64_at1", NoneType](
        int_at(0), float_at(1), float_at(2), float_at(3), float_at(4),
        float_at(5),
    )
    failures += check_odd_one_out("abi_int64_at1", 0, False)

    reset()
    external_call["abi_int64_at2", NoneType](
        float_at(0), int_at(1), float_at(2), float_at(3), float_at(4),
        float_at(5),
    )
    failures += check_odd_one_out("abi_int64_at2", 1, False)

    reset()
    external_call["abi_int64_at3", NoneType](
        float_at(0), float_at(1), int_at(2), float_at(3), float_at(4),
        float_at(5),
    )
    failures += check_odd_one_out("abi_int64_at3", 2, False)

    reset()
    external_call["abi_int64_at4", NoneType](
        float_at(0), float_at(1), float_at(2), int_at(3), float_at(4),
        float_at(5),
    )
    failures += check_odd_one_out("abi_int64_at4", 3, False)

    reset()
    external_call["abi_int64_at5", NoneType](
        float_at(0), float_at(1), float_at(2), float_at(3), int_at(4),
        float_at(5),
    )
    failures += check_odd_one_out("abi_int64_at5", 4, False)

    reset()
    external_call["abi_int64_at6", NoneType](
        float_at(0), float_at(1), float_at(2), float_at(3), float_at(4),
        int_at(5),
    )
    failures += check_odd_one_out("abi_int64_at6", 5, False)

    return failures


# The narrow version of the same thing. The register allocation question is
# identical, but the half of the register that goes unused is different, which
# catches a lowering that picks the right register and the wrong width.
def narrow_int_at(index: Int) -> Int32:
    return Int32(300 + index)


def narrow_float_at(index: Int) -> Float32:
    return Float32(index * 4 + 1) + Float32(0.5)


def check_narrow_odd_one_out(probe: StaticString, odd: Int) -> Int:
    var failures = check_count(probe, 6)
    for index in range(6):
        if index == odd:
            failures += check_float(
                probe, index, Float64(narrow_float_at(index))
            )
        else:
            failures += check_int(probe, index, Int64(narrow_int_at(index)))
    return failures


def test_float32_positions() -> Int:
    var failures = 0

    reset()
    external_call["abi_float32_at1", NoneType](
        narrow_float_at(0),
        narrow_int_at(1),
        narrow_int_at(2),
        narrow_int_at(3),
        narrow_int_at(4),
        narrow_int_at(5),
    )
    failures += check_narrow_odd_one_out("abi_float32_at1", 0)

    reset()
    external_call["abi_float32_at2", NoneType](
        narrow_int_at(0),
        narrow_float_at(1),
        narrow_int_at(2),
        narrow_int_at(3),
        narrow_int_at(4),
        narrow_int_at(5),
    )
    failures += check_narrow_odd_one_out("abi_float32_at2", 1)

    reset()
    external_call["abi_float32_at3", NoneType](
        narrow_int_at(0),
        narrow_int_at(1),
        narrow_float_at(2),
        narrow_int_at(3),
        narrow_int_at(4),
        narrow_int_at(5),
    )
    failures += check_narrow_odd_one_out("abi_float32_at3", 2)

    reset()
    external_call["abi_float32_at4", NoneType](
        narrow_int_at(0),
        narrow_int_at(1),
        narrow_int_at(2),
        narrow_float_at(3),
        narrow_int_at(4),
        narrow_int_at(5),
    )
    failures += check_narrow_odd_one_out("abi_float32_at4", 3)

    reset()
    external_call["abi_float32_at5", NoneType](
        narrow_int_at(0),
        narrow_int_at(1),
        narrow_int_at(2),
        narrow_int_at(3),
        narrow_float_at(4),
        narrow_int_at(5),
    )
    failures += check_narrow_odd_one_out("abi_float32_at5", 4)

    reset()
    external_call["abi_float32_at6", NoneType](
        narrow_int_at(0),
        narrow_int_at(1),
        narrow_int_at(2),
        narrow_int_at(3),
        narrow_int_at(4),
        narrow_float_at(5),
    )
    failures += check_narrow_odd_one_out("abi_float32_at6", 5)

    return failures


# ===-----------------------------------------------------------------------===#
# Mixed signatures
# ===-----------------------------------------------------------------------===#


def test_mixed() -> Int:
    var failures = 0

    comptime ifif = "abi_mixed_ifif_x6"
    reset()
    external_call[ifif, NoneType](
        Int32(71), Float64(72.5), Int32(73), Float64(74.5), Int32(75),
        Float64(76.5),
    )
    failures += check_count(ifif, 6)
    failures += check_int(ifif, 0, 71)
    failures += check_float(ifif, 1, 72.5)
    failures += check_int(ifif, 2, 73)
    failures += check_float(ifif, 3, 74.5)
    failures += check_int(ifif, 4, 75)
    failures += check_float(ifif, 5, 76.5)

    comptime fifi = "abi_mixed_fifi_x6"
    reset()
    external_call[fifi, NoneType](
        Float64(81.5), Int32(82), Float64(83.5), Int32(84), Float64(85.5),
        Int32(86),
    )
    failures += check_count(fifi, 6)
    failures += check_float(fifi, 0, 81.5)
    failures += check_int(fifi, 1, 82)
    failures += check_float(fifi, 2, 83.5)
    failures += check_int(fifi, 3, 84)
    failures += check_float(fifi, 4, 85.5)
    failures += check_int(fifi, 5, 86)

    return failures


# ===-----------------------------------------------------------------------===#
# Nine arguments, which spills on both platforms
# ===-----------------------------------------------------------------------===#
#
# Win64 spills from the fifth argument whatever its type. System V spills from
# the seventh integer and the ninth float, counted separately. So the same call
# has a different split between registers and stack on the two platforms, and
# the stack half is only checked by running it.


def test_int64_spill() -> Int:
    comptime probe = "abi_int64_x9"
    reset()
    external_call[probe, NoneType](
        int_at(0), int_at(1), int_at(2), int_at(3), int_at(4), int_at(5),
        int_at(6), int_at(7), int_at(8),
    )
    var failures = check_count(probe, 9)
    for index in range(9):
        failures += check_int(probe, index, int_at(index))
    return failures


def test_float64_spill() -> Int:
    comptime probe = "abi_float64_x9"
    reset()
    external_call[probe, NoneType](
        float_at(0), float_at(1), float_at(2), float_at(3), float_at(4),
        float_at(5), float_at(6), float_at(7), float_at(8),
    )
    var failures = check_count(probe, 9)
    for index in range(9):
        failures += check_float(probe, index, float_at(index))
    return failures


def test_mixed_spill() -> Int:
    comptime probe = "abi_mixed_x9"
    reset()
    external_call[probe, NoneType](
        Int32(91),
        Float64(92.5),
        Int64(93),
        Float32(94.5),
        Int32(95),
        Float64(96.5),
        Int64(97),
        Float32(98.5),
        Int32(99),
    )
    var failures = check_count(probe, 9)
    failures += check_int(probe, 0, 91)
    failures += check_float(probe, 1, 92.5)
    failures += check_int(probe, 2, 93)
    failures += check_float(probe, 3, 94.5)
    failures += check_int(probe, 4, 95)
    failures += check_float(probe, 5, 96.5)
    failures += check_int(probe, 6, 97)
    failures += check_float(probe, 7, 98.5)
    failures += check_int(probe, 8, 99)
    return failures


# ===-----------------------------------------------------------------------===#
# Returns
# ===-----------------------------------------------------------------------===#


def test_returns() -> Int:
    var failures = 0

    failures += check_returned_int(
        "abi_ret_int8",
        Int64(external_call["abi_ret_int8", Int8](Int8(41))),
        42,
    )
    failures += check_returned_int(
        "abi_ret_int16",
        Int64(external_call["abi_ret_int16", Int16](Int16(4141))),
        4142,
    )
    failures += check_returned_int(
        "abi_ret_int32",
        Int64(external_call["abi_ret_int32", Int32](Int32(414141))),
        414142,
    )
    failures += check_returned_int(
        "abi_ret_int64",
        external_call["abi_ret_int64", Int64](Int64(41414141414141)),
        41414141414142,
    )
    failures += check_returned_float(
        "abi_ret_float32",
        Float64(external_call["abi_ret_float32", Float32](Float32(41.5))),
        42.5,
    )
    failures += check_returned_float(
        "abi_ret_float64",
        external_call["abi_ret_float64", Float64](Float64(41.5)),
        42.5,
    )

    # A return from a call that has already used the register file. The return
    # register is not an argument register under either ABI, but the code that
    # places the return is the code that places the arguments, and this is the
    # shape that catches it carrying the wrong state across.
    var int_sum = Int64(0)
    var float_sum = Float64(0)
    for index in range(6):
        int_sum += int_at(index)
        float_sum += float_at(index)

    failures += check_returned_int(
        "abi_ret_int64_after_x6",
        external_call["abi_ret_int64_after_x6", Int64](
            int_at(0), int_at(1), int_at(2), int_at(3), int_at(4), int_at(5)
        ),
        int_sum,
    )
    failures += check_returned_float(
        "abi_ret_float64_after_x6",
        external_call["abi_ret_float64_after_x6", Float64](
            float_at(0), float_at(1), float_at(2), float_at(3), float_at(4),
            float_at(5),
        ),
        float_sum,
    )
    failures += check_returned_float(
        "abi_ret_float64_after_mixed",
        external_call["abi_ret_float64_after_mixed", Float64](
            Int32(1), Float64(2.5), Int64(3), Float32(4.5), Int32(5),
            Float64(6.5),
        ),
        22.5,
    )

    return failures


def main():
    var failures = 0
    failures += test_int8()
    failures += test_int16()
    failures += test_int32()
    failures += test_int64()
    failures += test_float32()
    failures += test_float64()
    failures += test_float64_positions()
    failures += test_int64_positions()
    failures += test_float32_positions()
    failures += test_mixed()
    failures += test_int64_spill()
    failures += test_float64_spill()
    failures += test_mixed_spill()
    failures += test_returns()

    if failures != 0:
        print(failures, "checks failed")
        exit(1)
    print("scalar ABI conformance passed")
