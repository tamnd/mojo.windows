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
"""The stack a call is made on, rather than what is passed on it.

Everything else in this suite asks where an argument went. This asks about the
frame underneath it, which the caller has to get right before any argument is
placed, and which Windows has two more rules about than Linux does.

Shadow space is the first. A Win64 caller reserves thirty two bytes above the
return address whatever the call looks like, and they belong to the callee, to
spill its four register arguments into. A caller that skips the reservation has
given the callee thirty two bytes of its own live frame to write over.

Stack alignment is the second. Both conventions want the stack pointer to be a
multiple of sixteen at the call. Windows is the harder one because the shadow
space and the stack argument area are sized together, so a caller that adds the
two and forgets to round is misaligned by exactly eight, and only on the calls
where the argument count makes the total odd.

The red zone is the third and there is no test for it here. System V lets a leaf
function use the hundred and twenty eight bytes below the stack pointer without
reserving them and Windows does not, but a Windows caller that used one anyway
is correct right up until an interrupt or an exception lands on it, and a test
cannot arrange that. Not covered, and saying so is the most this file can do.

Prints nothing when everything passes and exits zero. Prints one line per
failure and exits one otherwise.
"""

from std.ffi import external_call
from std.sys import exit

from abi_probe import check_count, check_float, check_int, reset


def int_at(index: Int) -> Int64:
    """A distinct value per position, so a value in the wrong place shows."""
    return Int64(3000 + index * 13)


def float_at(index: Int) -> Float64:
    """The same idea for the floating point positions."""
    return Float64(index * 8 + 1) + 0.25


def check_alignment(probe: StaticString, got: Int32) -> Int:
    """Checks a probe found its own frame aligned to sixteen bytes.

    Args:
        probe: The name of the probe, used in the failure message.
        got: How far from a multiple of sixteen the probe's frame was.

    Returns:
        1 if the check failed, 0 if it passed.
    """
    if got == 0:
        return 0
    print(
        "FAIL",
        probe,
        "ran on a stack",
        got,
        "bytes off sixteen byte alignment",
    )
    return 1


def test_shadow_home() -> Int:
    """Four register arguments, read again after the callee makes its own call.

    The callee has nowhere to keep them across that call except the home slots,
    so this is the shape that uses the shadow space for the reason it exists.

    It is also the weaker of the two shadow space tests, and it is here for
    completeness rather than for what it catches. If the caller reserved
    nothing, the callee spills into the caller's frame and reads back what it
    just wrote, so the values are right and the damage is somewhere this probe
    cannot look. The next test is the one that sees it.
    """
    reset()
    external_call["abi_shadow_home", NoneType](
        int_at(0), int_at(1), int_at(2), int_at(3)
    )
    var failures = check_count("abi_shadow_home", 4)
    for index in range(4):
        failures += check_int("abi_shadow_home", index, int_at(index))
    return failures


def test_shadow_stack() -> Int:
    """The same with two arguments on the stack, which is the one that bites.

    A correct caller puts the fifth and sixth arguments immediately above the
    thirty two bytes it reserved. A caller that reserved nothing puts them where
    the shadow space belonged, which is where the callee spills, so the callee
    destroys its own fifth and sixth arguments before it reads them.
    """
    reset()
    external_call["abi_shadow_stack", NoneType](
        int_at(0), int_at(1), int_at(2), int_at(3), int_at(4), int_at(5)
    )
    var failures = check_count("abi_shadow_stack", 6)
    for index in range(6):
        failures += check_int("abi_shadow_stack", index, int_at(index))
    return failures


def test_shadow_mixed() -> Int:
    """The same again with the doubles interleaved.

    Floating point arguments have home slots too and they are the same four,
    because Win64 numbers the two register files together. A caller that sized
    the reservation by counting only the integer arguments gets this wrong and
    the two tests above right.
    """
    reset()
    external_call["abi_shadow_mixed", NoneType](
        int_at(0),
        float_at(1),
        int_at(2),
        float_at(3),
        int_at(4),
        float_at(5),
    )
    var failures = check_count("abi_shadow_mixed", 6)
    for index in range(6):
        if index % 2 == 0:
            failures += check_int("abi_shadow_mixed", index, int_at(index))
        else:
            failures += check_float("abi_shadow_mixed", index, float_at(index))
    return failures


def test_alignment() -> Int:
    """A plain call with nothing on the stack, which is the base case.

    The C side asks for a local aligned to sixteen and reports how far off it
    landed. The C compiler aligned it relative to the stack pointer it was
    handed and nothing realigns anything on the way in, so a non zero answer
    means the caller handed it a stack pointer that was not aligned.
    """
    var got = external_call["abi_frame_alignment", Int32]()
    return check_alignment("abi_frame_alignment", got)


def test_alignment_with_stack_arguments() -> Int:
    """One stack argument, then two, then five.

    The outgoing frame is the shadow space plus the stack arguments plus
    whatever padding keeps the total a multiple of sixteen. The odd counts are
    where the padding is needed, so a caller that adds the pieces without
    rounding is off by eight in the odd cases and correct in the even one, and
    having all three means being right by accident in one of them is not enough.
    """
    var odd = external_call["abi_frame_alignment_odd", Int32](
        int_at(0), int_at(1), int_at(2), int_at(3), int_at(4)
    )
    var failures = check_alignment("abi_frame_alignment_odd", odd)

    var even = external_call["abi_frame_alignment_even", Int32](
        int_at(0), int_at(1), int_at(2), int_at(3), int_at(4), int_at(5)
    )
    failures += check_alignment("abi_frame_alignment_even", even)

    var deep = external_call["abi_frame_alignment_deep", Int32](
        int_at(0),
        int_at(1),
        int_at(2),
        int_at(3),
        int_at(4),
        int_at(5),
        int_at(6),
        int_at(7),
        int_at(8),
    )
    failures += check_alignment("abi_frame_alignment_deep", deep)
    return failures


def main():
    var failures = test_shadow_home()
    failures += test_shadow_stack()
    failures += test_shadow_mixed()
    failures += test_alignment()
    failures += test_alignment_with_stack_arguments()

    if failures != 0:
        print(failures, "checks failed")
        exit(1)

    print("frame ABI conformance passed")
