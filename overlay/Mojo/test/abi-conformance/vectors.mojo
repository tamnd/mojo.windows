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
"""`SIMD` across the C boundary, against `__m128` on the other side.

The sharpest disagreement left in the suite. System V gives a sixteen byte
vector a class of its own and passes it in an SSE register. Win64 has no such
class and nothing it considers wide enough, so the vector is copied to memory
and passed as a pointer, and it comes back through a hidden pointer the caller
supplies. Same type, same source, and one convention puts it in a register while
the other never does.

Worth a file of its own rather than a section in `structs.mojo`, because a
lowering that has the struct rules right can still be wrong here. The struct
rules turn on size, and these do not: sixteen bytes of two doubles in a struct
and sixteen bytes of two doubles in a vector are the same size and System V
treats them differently.

`SIMD` is also the type Mojo is built around, so this is the one part of the
suite where the thing being checked is a first class part of the language rather
than something reached for when talking to C.

Prints nothing when everything passes and exits zero. Prints one line per
failure and exits one otherwise.
"""

from std.ffi import external_call
from std.sys import exit

from abi_probe import (
    check_count,
    check_float,
    check_int,
    check_returned_float_field,
    check_size,
    reset,
)

comptime F4 = SIMD[DType.float32, 4]
comptime D2 = SIMD[DType.float64, 2]
comptime I4 = SIMD[DType.int32, 4]


def test_layout() -> Int:
    """Checks the three vector types are sixteen bytes here and in C.

    Same reason as the layout check in `structs.mojo`. Everything below is
    comparing two spellings of a type and means nothing if the two spellings
    are not the same size.
    """
    var failures = check_size[F4, "abi_size_v4f"]("SIMD[float32, 4]")
    failures += check_size[D2, "abi_size_v2d"]("SIMD[float64, 2]")
    failures += check_size[I4, "abi_size_v4i"]("SIMD[int32, 4]")
    return failures


def lane(index: Int) -> Float64:
    """A distinct value per lane, exactly representable as a 32 bit float."""
    return Float64(index * 4 + 1) + 0.5


def float4(base: Int) -> F4:
    """Four consecutive lane values, starting at `base`."""
    return F4(
        Float32(lane(base)),
        Float32(lane(base + 1)),
        Float32(lane(base + 2)),
        Float32(lane(base + 3)),
    )


def test_float4() -> Int:
    """One vector on its own, which is the plain case both conventions differ
    on and the one everything below builds from.
    """
    reset()
    external_call["abi_v4f", NoneType](float4(0))
    var failures = check_count("abi_v4f", 4)
    for index in range(4):
        failures += check_float("abi_v4f", index, lane(index))
    return failures


def test_double2() -> Int:
    """Two doubles in the same sixteen bytes.

    The interesting one next to a struct of two doubles, which is byte for byte
    the same and which System V splits across two SSE registers rather than
    putting in one.
    """
    reset()
    external_call["abi_v2d", NoneType](D2(lane(0), lane(1)))
    var failures = check_count("abi_v2d", 2)
    failures += check_float("abi_v2d", 0, lane(0))
    failures += check_float("abi_v2d", 1, lane(1))
    return failures


def test_int4() -> Int:
    """An integer vector, which is the same sixteen bytes and the same class.

    Both conventions classify a vector by its width and not by what is in it,
    so this should behave exactly like the float one. Here to say so out loud,
    because a lowering that reached the right answer by looking at the element
    type would pass everything above and fail this.
    """
    reset()
    external_call["abi_v4i", NoneType](I4(11, 22, 33, 44))
    var failures = check_count("abi_v4i", 4)
    failures += check_int("abi_v4i", 0, 11)
    failures += check_int("abi_v4i", 1, 22)
    failures += check_int("abi_v4i", 2, 33)
    failures += check_int("abi_v4i", 3, 44)
    return failures


def test_two_vectors() -> Int:
    """Two of them, which is two SSE registers on Linux and two pointers on
    Windows. The second one is where a lowering that got the first right by
    accident stops working.
    """
    reset()
    external_call["abi_v4f_x2", NoneType](float4(0), float4(4))
    var failures = check_count("abi_v4f_x2", 4)
    failures += check_float("abi_v4f_x2", 0, lane(0))
    failures += check_float("abi_v4f_x2", 1, lane(3))
    failures += check_float("abi_v4f_x2", 2, lane(4))
    failures += check_float("abi_v4f_x2", 3, lane(7))
    return failures


def test_vector_then_scalars() -> Int:
    """A vector with scalars after it.

    On Windows the vector consumed a register slot to hold its address, so the
    scalars sit one slot further along than counting register files would
    suggest. They are what shows if the vector went somewhere else.
    """
    reset()
    external_call["abi_v4f_then", NoneType](float4(0), lane(8), Int64(7777))
    var failures = check_count("abi_v4f_then", 4)
    failures += check_float("abi_v4f_then", 0, lane(0))
    failures += check_float("abi_v4f_then", 1, lane(3))
    failures += check_float("abi_v4f_then", 2, lane(8))
    failures += check_int("abi_v4f_then", 3, 7777)
    return failures


def test_scalars_then_vector() -> Int:
    """The same the other way round, so the vector has to land correctly after
    the scalars have taken their places.
    """
    reset()
    external_call["abi_v4f_after", NoneType](Int64(8888), lane(9), float4(0))
    var failures = check_count("abi_v4f_after", 4)
    failures += check_int("abi_v4f_after", 0, 8888)
    failures += check_float("abi_v4f_after", 1, lane(9))
    failures += check_float("abi_v4f_after", 2, lane(0))
    failures += check_float("abi_v4f_after", 3, lane(3))
    return failures


def test_vector_spill() -> Int:
    """Five vectors, which is past every SSE register System V hands out and
    past every register slot Win64 has, so the last of them are on the stack
    under both conventions and by different arithmetic.
    """
    reset()
    external_call["abi_v4f_x5", NoneType](
        float4(0), float4(4), float4(8), float4(12), float4(16)
    )
    var failures = check_count("abi_v4f_x5", 5)
    for index in range(5):
        failures += check_float("abi_v4f_x5", index, lane(index * 4))
    return failures


def test_returns() -> Int:
    """Vectors coming back. Each probe adds one to every lane."""
    var got4 = external_call["abi_ret_v4f", F4](float4(0))
    var failures = 0
    for index in range(4):
        failures += check_returned_float_field(
            "abi_ret_v4f", index, Float64(got4[index]), lane(index) + 1.0
        )

    var got2 = external_call["abi_ret_v2d", D2](D2(lane(0), lane(1)))
    for index in range(2):
        failures += check_returned_float_field(
            "abi_ret_v2d", index, got2[index], lane(index) + 1.0
        )
    return failures


def test_return_with_arguments() -> Int:
    """A returned vector from a call that has already spent its register slots.

    On Windows the hidden pointer for the return value takes the first slot and
    every argument moves along by one, so this is where the return path and the
    argument path can get in each other's way.
    """
    reset()
    var got = external_call["abi_ret_v4f_after", F4](
        Int64(101), Int64(202), Int64(303), float4(0)
    )
    var failures = check_count("abi_ret_v4f_after", 3)
    failures += check_int("abi_ret_v4f_after", 0, 101)
    failures += check_int("abi_ret_v4f_after", 1, 202)
    failures += check_int("abi_ret_v4f_after", 2, 303)
    for index in range(4):
        failures += check_returned_float_field(
            "abi_ret_v4f_after", index, Float64(got[index]), lane(index) + 1.0
        )
    return failures


def main():
    var failures = test_layout()
    failures += test_float4()
    failures += test_double2()
    failures += test_int4()
    failures += test_two_vectors()
    failures += test_vector_then_scalars()
    failures += test_scalars_then_vector()
    failures += test_vector_spill()
    failures += test_returns()
    failures += test_return_with_arguments()

    if failures != 0:
        print(failures, "checks failed")
        exit(1)

    print("vector ABI conformance passed")
