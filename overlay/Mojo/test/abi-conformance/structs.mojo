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
"""Struct arguments and struct returns across the C boundary.

The place where System V and Win64 disagree most. Win64 looks at nothing but the
size: exactly 1, 2, 4 or 8 bytes goes in a register by value and everything else
is copied to memory and passed as a hidden pointer that takes a register slot of
its own. System V cuts the struct into eight byte pieces, classifies each piece
by what is in it, and hands out up to two registers from whichever register
files those pieces call for.

So a twelve byte struct of three ints is two registers on Linux and a pointer on
Windows, and sixteen bytes of two doubles is two SSE registers on Linux and a
pointer on Windows. Each of these structs is declared twice, once here and once
in probe_structs.c where the platform C compiler decides what actually happens
to it.

Prints nothing when everything passes and exits zero. Prints one line per
failure and exits one otherwise.
"""

from std.ffi import external_call
from std.sys import exit, size_of

from abi_probe import (
    check_count,
    check_float,
    check_int,
    check_returned_float_field,
    check_returned_int_field,
    reset,
)


# ===-----------------------------------------------------------------------===#
# The shapes, declared to match probe_structs.c field for field
# ===-----------------------------------------------------------------------===#


# Sizes one through eight, all bytes, so the size is exactly the field count and
# alignment never rounds it up. Four of these are sizes Win64 passes in a
# register and four are sizes it does not, which is the contrast worth having.
@fieldwise_init
struct B1(TrivialRegisterPassable):
    var f0: UInt8


@fieldwise_init
struct B2(TrivialRegisterPassable):
    var f0: UInt8
    var f1: UInt8


@fieldwise_init
struct B3(TrivialRegisterPassable):
    var f0: UInt8
    var f1: UInt8
    var f2: UInt8


@fieldwise_init
struct B4(TrivialRegisterPassable):
    var f0: UInt8
    var f1: UInt8
    var f2: UInt8
    var f3: UInt8


@fieldwise_init
struct B5(TrivialRegisterPassable):
    var f0: UInt8
    var f1: UInt8
    var f2: UInt8
    var f3: UInt8
    var f4: UInt8


@fieldwise_init
struct B6(TrivialRegisterPassable):
    var f0: UInt8
    var f1: UInt8
    var f2: UInt8
    var f3: UInt8
    var f4: UInt8
    var f5: UInt8


@fieldwise_init
struct B7(TrivialRegisterPassable):
    var f0: UInt8
    var f1: UInt8
    var f2: UInt8
    var f3: UInt8
    var f4: UInt8
    var f5: UInt8
    var f6: UInt8


@fieldwise_init
struct B8(TrivialRegisterPassable):
    var f0: UInt8
    var f1: UInt8
    var f2: UInt8
    var f3: UInt8
    var f4: UInt8
    var f5: UInt8
    var f6: UInt8
    var f7: UInt8


# The control case. Both conventions put eight bytes of two integers in a single
# integer register, so a failure here is something more basic than the ABI.
@fieldwise_init
struct TwoInts(TrivialRegisterPassable):
    var a: Int32
    var b: Int32


# Twelve bytes. Two integer registers on System V, a hidden pointer on Win64.
@fieldwise_init
struct ThreeInts(TrivialRegisterPassable):
    var a: Int32
    var b: Int32
    var c: Int32


# Sixteen bytes of floating point. Two SSE registers on System V, a hidden
# pointer on Win64.
@fieldwise_init
struct TwoDoubles(TrivialRegisterPassable):
    var a: Float64
    var b: Float64


# One field of each class in eight bytes. System V says a piece with any integer
# in it is an integer piece, so the float travels in an integer register with
# the int packed beside it. Win64 passes eight bytes in an integer register for
# its own unrelated reason. Same destination, different reasoning, which is the
# sort of agreement that stops holding the moment the field order changes.
@fieldwise_init
struct FloatAndInt(TrivialRegisterPassable):
    var a: Float32
    var b: Int32


# Sixteen bytes of integers, the last size System V still passes in registers.
@fieldwise_init
struct TwoLongs(TrivialRegisterPassable):
    var a: Int64
    var b: Int64


# Twenty four bytes, over the limit for both, so memory either way.
@fieldwise_init
struct ThreeLongs(TrivialRegisterPassable):
    var a: Int64
    var b: Int64
    var c: Int64


# A struct inside a struct. System V flattens before it classifies, so this is
# classified exactly like ThreeInts, and a compiler that treats the nested field
# as one indivisible unit gets a different answer.
@fieldwise_init
struct Nested(TrivialRegisterPassable):
    var inner: TwoInts
    var c: Int32


# ===-----------------------------------------------------------------------===#
# Layout agreement
# ===-----------------------------------------------------------------------===#
#
# Every shape above is declared twice, here and in probe_structs.c, and the
# whole suite rests on the two declarations describing the same thing. If they
# do not then the results mean nothing: a B3 that is four bytes on this side and
# three on the other is not the case the name says it is, and it would sail
# through on System V while testing something else entirely.
#
# So ask the other side. The size is what both conventions key on, so it is also
# the thing worth agreeing about, and a failure here should be read before any
# other failure in the run.


def check_size[type: AnyType, size_probe: StaticString](
    shape: StaticString
) -> Int:
    var theirs = Int(external_call[size_probe, Int32]())
    var ours = size_of[type]()
    if ours == theirs:
        return 0
    print("FAIL", shape, "is", ours, "bytes here and", theirs, "bytes in C")
    return 1


def test_layout() -> Int:
    var failures = check_size[B1, "abi_size_b1"]("B1")
    failures += check_size[B2, "abi_size_b2"]("B2")
    failures += check_size[B3, "abi_size_b3"]("B3")
    failures += check_size[B4, "abi_size_b4"]("B4")
    failures += check_size[B5, "abi_size_b5"]("B5")
    failures += check_size[B6, "abi_size_b6"]("B6")
    failures += check_size[B7, "abi_size_b7"]("B7")
    failures += check_size[B8, "abi_size_b8"]("B8")
    failures += check_size[TwoInts, "abi_size_two_ints"]("TwoInts")
    failures += check_size[ThreeInts, "abi_size_three_ints"]("ThreeInts")
    failures += check_size[TwoDoubles, "abi_size_two_doubles"]("TwoDoubles")
    failures += check_size[FloatAndInt, "abi_size_float_and_int"](
        "FloatAndInt"
    )
    failures += check_size[TwoLongs, "abi_size_two_longs"]("TwoLongs")
    failures += check_size[ThreeLongs, "abi_size_three_longs"]("ThreeLongs")
    failures += check_size[Nested, "abi_size_nested"]("Nested")
    return failures


# ===-----------------------------------------------------------------------===#
# Passing
# ===-----------------------------------------------------------------------===#


# Distinct per field, so a field that lands one slot off is caught rather than
# matching the value that was supposed to be there.
def byte_at(index: Int) -> UInt8:
    return UInt8(10 + index)


def check_bytes(probe: StaticString, fields: Int) -> Int:
    var failures = check_count(probe, fields)
    for index in range(fields):
        failures += check_int(probe, index, Int64(byte_at(index)))
    return failures


def test_byte_structs() -> Int:
    var failures = 0

    reset()
    external_call["abi_struct_b1", NoneType](B1(byte_at(0)))
    failures += check_bytes("abi_struct_b1", 1)

    reset()
    external_call["abi_struct_b2", NoneType](B2(byte_at(0), byte_at(1)))
    failures += check_bytes("abi_struct_b2", 2)

    reset()
    external_call["abi_struct_b3", NoneType](
        B3(byte_at(0), byte_at(1), byte_at(2))
    )
    failures += check_bytes("abi_struct_b3", 3)

    reset()
    external_call["abi_struct_b4", NoneType](
        B4(byte_at(0), byte_at(1), byte_at(2), byte_at(3))
    )
    failures += check_bytes("abi_struct_b4", 4)

    reset()
    external_call["abi_struct_b5", NoneType](
        B5(byte_at(0), byte_at(1), byte_at(2), byte_at(3), byte_at(4))
    )
    failures += check_bytes("abi_struct_b5", 5)

    reset()
    external_call["abi_struct_b6", NoneType](
        B6(
            byte_at(0),
            byte_at(1),
            byte_at(2),
            byte_at(3),
            byte_at(4),
            byte_at(5),
        )
    )
    failures += check_bytes("abi_struct_b6", 6)

    reset()
    external_call["abi_struct_b7", NoneType](
        B7(
            byte_at(0),
            byte_at(1),
            byte_at(2),
            byte_at(3),
            byte_at(4),
            byte_at(5),
            byte_at(6),
        )
    )
    failures += check_bytes("abi_struct_b7", 7)

    reset()
    external_call["abi_struct_b8", NoneType](
        B8(
            byte_at(0),
            byte_at(1),
            byte_at(2),
            byte_at(3),
            byte_at(4),
            byte_at(5),
            byte_at(6),
            byte_at(7),
        )
    )
    failures += check_bytes("abi_struct_b8", 8)

    return failures


def test_scalar_field_structs() -> Int:
    var failures = 0

    reset()
    external_call["abi_struct_two_ints", NoneType](TwoInts(101, 102))
    failures += check_count("abi_struct_two_ints", 2)
    failures += check_int("abi_struct_two_ints", 0, 101)
    failures += check_int("abi_struct_two_ints", 1, 102)

    reset()
    external_call["abi_struct_three_ints", NoneType](ThreeInts(201, 202, 203))
    failures += check_count("abi_struct_three_ints", 3)
    failures += check_int("abi_struct_three_ints", 0, 201)
    failures += check_int("abi_struct_three_ints", 1, 202)
    failures += check_int("abi_struct_three_ints", 2, 203)

    reset()
    external_call["abi_struct_two_doubles", NoneType](
        TwoDoubles(301.5, 302.25)
    )
    failures += check_count("abi_struct_two_doubles", 2)
    failures += check_float("abi_struct_two_doubles", 0, 301.5)
    failures += check_float("abi_struct_two_doubles", 1, 302.25)

    reset()
    external_call["abi_struct_float_and_int", NoneType](
        FloatAndInt(401.5, 402)
    )
    failures += check_count("abi_struct_float_and_int", 2)
    failures += check_float("abi_struct_float_and_int", 0, 401.5)
    failures += check_int("abi_struct_float_and_int", 1, 402)

    reset()
    external_call["abi_struct_two_longs", NoneType](TwoLongs(501, 502))
    failures += check_count("abi_struct_two_longs", 2)
    failures += check_int("abi_struct_two_longs", 0, 501)
    failures += check_int("abi_struct_two_longs", 1, 502)

    reset()
    external_call["abi_struct_three_longs", NoneType](
        ThreeLongs(601, 602, 603)
    )
    failures += check_count("abi_struct_three_longs", 3)
    failures += check_int("abi_struct_three_longs", 0, 601)
    failures += check_int("abi_struct_three_longs", 1, 602)
    failures += check_int("abi_struct_three_longs", 2, 603)

    reset()
    external_call["abi_struct_nested", NoneType](Nested(TwoInts(701, 702), 703))
    failures += check_count("abi_struct_nested", 3)
    failures += check_int("abi_struct_nested", 0, 701)
    failures += check_int("abi_struct_nested", 1, 702)
    failures += check_int("abi_struct_nested", 2, 703)

    return failures


# ===-----------------------------------------------------------------------===#
# Passing alongside other arguments
# ===-----------------------------------------------------------------------===#
#
# A struct on its own only says whether the struct arrived. These say whether it
# took the register slots it was supposed to, because whatever comes after it is
# wrong if it did not.


def test_structs_with_neighbours() -> Int:
    var failures = 0

    comptime then = "abi_struct_three_ints_then"
    reset()
    external_call["abi_struct_three_ints_then", NoneType](
        ThreeInts(801, 802, 803), Int64(804), Int64(805), Int64(806)
    )
    failures += check_count(then, 6)
    for index in range(6):
        failures += check_int(then, index, Int64(801 + index))

    comptime after = "abi_struct_after_three"
    reset()
    external_call["abi_struct_after_three", NoneType](
        Int64(901), Int64(902), Int64(903), ThreeInts(904, 905, 906)
    )
    failures += check_count(after, 6)
    for index in range(6):
        failures += check_int(after, index, Int64(901 + index))

    comptime doubles = "abi_struct_two_doubles_then"
    reset()
    external_call["abi_struct_two_doubles_then", NoneType](
        TwoDoubles(1001.5, 1002.5), Float64(1003.5), Float64(1004.5)
    )
    failures += check_count(doubles, 4)
    for index in range(4):
        failures += check_float(doubles, index, Float64(1001 + index) + 0.5)

    comptime between = "abi_struct_b3_between"
    reset()
    external_call["abi_struct_b3_between", NoneType](
        Int64(1101), B3(byte_at(0), byte_at(1), byte_at(2)), Int64(1102)
    )
    failures += check_count(between, 5)
    failures += check_int(between, 0, 1101)
    failures += check_int(between, 1, Int64(byte_at(0)))
    failures += check_int(between, 2, Int64(byte_at(1)))
    failures += check_int(between, 3, Int64(byte_at(2)))
    failures += check_int(between, 4, 1102)

    return failures


# ===-----------------------------------------------------------------------===#
# Returning
# ===-----------------------------------------------------------------------===#
#
# Win64 returns 1, 2, 4 and 8 byte structs in RAX and writes anything else
# through a hidden pointer the caller passes as an invisible first argument,
# which shifts every real argument along by one. System V classifies the return
# the way it classifies an argument, so sixteen bytes comes back in two
# registers there and through memory on Windows.


def test_byte_struct_returns() -> Int:
    var failures = 0

    comptime b1 = "abi_ret_b1"
    var r1 = external_call["abi_ret_b1", B1](B1(byte_at(0)))
    failures += check_returned_int_field(b1, 0, Int64(r1.f0), Int64(byte_at(0)) + 1)

    comptime b3 = "abi_ret_b3"
    var r3 = external_call["abi_ret_b3", B3](
        B3(byte_at(0), byte_at(1), byte_at(2))
    )
    failures += check_returned_int_field(b3, 0, Int64(r3.f0), Int64(byte_at(0)) + 1)
    failures += check_returned_int_field(b3, 1, Int64(r3.f1), Int64(byte_at(1)) + 1)
    failures += check_returned_int_field(b3, 2, Int64(r3.f2), Int64(byte_at(2)) + 1)

    comptime b5 = "abi_ret_b5"
    var r5 = external_call["abi_ret_b5", B5](
        B5(byte_at(0), byte_at(1), byte_at(2), byte_at(3), byte_at(4))
    )
    failures += check_returned_int_field(b5, 0, Int64(r5.f0), Int64(byte_at(0)) + 1)
    failures += check_returned_int_field(b5, 1, Int64(r5.f1), Int64(byte_at(1)) + 1)
    failures += check_returned_int_field(b5, 2, Int64(r5.f2), Int64(byte_at(2)) + 1)
    failures += check_returned_int_field(b5, 3, Int64(r5.f3), Int64(byte_at(3)) + 1)
    failures += check_returned_int_field(b5, 4, Int64(r5.f4), Int64(byte_at(4)) + 1)

    comptime b7 = "abi_ret_b7"
    var r7 = external_call["abi_ret_b7", B7](
        B7(
            byte_at(0),
            byte_at(1),
            byte_at(2),
            byte_at(3),
            byte_at(4),
            byte_at(5),
            byte_at(6),
        )
    )
    failures += check_returned_int_field(b7, 0, Int64(r7.f0), Int64(byte_at(0)) + 1)
    failures += check_returned_int_field(b7, 1, Int64(r7.f1), Int64(byte_at(1)) + 1)
    failures += check_returned_int_field(b7, 2, Int64(r7.f2), Int64(byte_at(2)) + 1)
    failures += check_returned_int_field(b7, 3, Int64(r7.f3), Int64(byte_at(3)) + 1)
    failures += check_returned_int_field(b7, 4, Int64(r7.f4), Int64(byte_at(4)) + 1)
    failures += check_returned_int_field(b7, 5, Int64(r7.f5), Int64(byte_at(5)) + 1)
    failures += check_returned_int_field(b7, 6, Int64(r7.f6), Int64(byte_at(6)) + 1)

    comptime b8 = "abi_ret_b8"
    var r8 = external_call["abi_ret_b8", B8](
        B8(
            byte_at(0),
            byte_at(1),
            byte_at(2),
            byte_at(3),
            byte_at(4),
            byte_at(5),
            byte_at(6),
            byte_at(7),
        )
    )
    failures += check_returned_int_field(b8, 0, Int64(r8.f0), Int64(byte_at(0)) + 1)
    failures += check_returned_int_field(b8, 1, Int64(r8.f1), Int64(byte_at(1)) + 1)
    failures += check_returned_int_field(b8, 2, Int64(r8.f2), Int64(byte_at(2)) + 1)
    failures += check_returned_int_field(b8, 3, Int64(r8.f3), Int64(byte_at(3)) + 1)
    failures += check_returned_int_field(b8, 4, Int64(r8.f4), Int64(byte_at(4)) + 1)
    failures += check_returned_int_field(b8, 5, Int64(r8.f5), Int64(byte_at(5)) + 1)
    failures += check_returned_int_field(b8, 6, Int64(r8.f6), Int64(byte_at(6)) + 1)
    failures += check_returned_int_field(b8, 7, Int64(r8.f7), Int64(byte_at(7)) + 1)

    return failures


def test_scalar_field_struct_returns() -> Int:
    var failures = 0

    comptime two_ints = "abi_ret_two_ints"
    var ri2 = external_call["abi_ret_two_ints", TwoInts](TwoInts(101, 102))
    failures += check_returned_int_field(two_ints, 0, Int64(ri2.a), 102)
    failures += check_returned_int_field(two_ints, 1, Int64(ri2.b), 103)

    comptime three_ints = "abi_ret_three_ints"
    var ri3 = external_call["abi_ret_three_ints", ThreeInts](
        ThreeInts(201, 202, 203)
    )
    failures += check_returned_int_field(three_ints, 0, Int64(ri3.a), 202)
    failures += check_returned_int_field(three_ints, 1, Int64(ri3.b), 203)
    failures += check_returned_int_field(three_ints, 2, Int64(ri3.c), 204)

    comptime two_doubles = "abi_ret_two_doubles"
    var rd2 = external_call["abi_ret_two_doubles", TwoDoubles](
        TwoDoubles(301.5, 302.25)
    )
    failures += check_returned_float_field(two_doubles, 0, rd2.a, 302.5)
    failures += check_returned_float_field(two_doubles, 1, rd2.b, 303.25)

    comptime float_and_int = "abi_ret_float_and_int"
    var rfi = external_call["abi_ret_float_and_int", FloatAndInt](
        FloatAndInt(401.5, 402)
    )
    failures += check_returned_float_field(
        float_and_int, 0, Float64(rfi.a), 402.5
    )
    failures += check_returned_int_field(float_and_int, 1, Int64(rfi.b), 403)

    comptime two_longs = "abi_ret_two_longs"
    var rl2 = external_call["abi_ret_two_longs", TwoLongs](TwoLongs(501, 502))
    failures += check_returned_int_field(two_longs, 0, rl2.a, 502)
    failures += check_returned_int_field(two_longs, 1, rl2.b, 503)

    comptime three_longs = "abi_ret_three_longs"
    var rl3 = external_call["abi_ret_three_longs", ThreeLongs](
        ThreeLongs(601, 602, 603)
    )
    failures += check_returned_int_field(three_longs, 0, rl3.a, 602)
    failures += check_returned_int_field(three_longs, 1, rl3.b, 603)
    failures += check_returned_int_field(three_longs, 2, rl3.c, 604)

    comptime nested = "abi_ret_nested"
    var rn = external_call["abi_ret_nested", Nested](
        Nested(TwoInts(701, 702), 703)
    )
    failures += check_returned_int_field(nested, 0, Int64(rn.inner.a), 702)
    failures += check_returned_int_field(nested, 1, Int64(rn.inner.b), 703)
    failures += check_returned_int_field(nested, 2, Int64(rn.c), 704)

    return failures


def test_return_with_arguments() -> Int:
    comptime probe = "abi_ret_three_ints_after"
    reset()
    var result = external_call["abi_ret_three_ints_after", ThreeInts](
        Int64(1201), Int64(1202), ThreeInts(1203, 1204, 1205)
    )
    var failures = check_count(probe, 2)
    failures += check_int(probe, 0, 1201)
    failures += check_int(probe, 1, 1202)
    failures += check_returned_int_field(probe, 0, Int64(result.a), 1204)
    failures += check_returned_int_field(probe, 1, Int64(result.b), 1205)
    failures += check_returned_int_field(probe, 2, Int64(result.c), 1206)
    return failures


def main():
    var failures = test_layout()
    failures += test_byte_structs()
    failures += test_scalar_field_structs()
    failures += test_structs_with_neighbours()
    failures += test_byte_struct_returns()
    failures += test_scalar_field_struct_returns()
    failures += test_return_with_arguments()

    if failures != 0:
        print(failures, "checks failed")
        exit(1)
    print("struct ABI conformance passed")
