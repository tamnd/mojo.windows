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
"""How wide the C types are, and what a bool looks like on the way in.

The other two files in this suite ask where an argument lands. This one asks how
many bytes it is before it goes anywhere, which is a separate question and the
only one in the suite where the two platforms are supposed to give different
answers.

Linux and macOS are LP64, so C `long` is 64 bits there. Windows is LLP64 and
leaves it at 32, giving the extra width to `long long` and to pointers. Nothing
in the language says which one you are on, so the standard library has to work it
out from the target, and if it gets it wrong then every `external_call` whose C
signature mentions `long` sends the wrong number of bytes.

Which mostly does not show. Every argument takes a full eight byte slot whatever
its width, in a register or on the stack, and the callee reads the low end of
that slot, which is the end a small number lives in. Sending 64 bits where the
callee reads 32 therefore lands the right value in the right place, and the value
checks below all pass with the width wrong. Where it does bite is a value that
does not fit in 32 bits, a `long` inside a struct where the width moves the
offset of every field after it, and varargs where the callee walks the list by
the width it was told. None of those three are in this file yet.

So the width gets a check of its own rather than being something the value checks
would have caught anyway. The widths are not written down here either. The C side
reports `sizeof` for each type and Mojo compares against `size_of`, which means
this file is right on any platform someone points it at, including the ones
nobody has tried yet.

Prints nothing when everything passes and exits zero. Prints one line per
failure and exits one otherwise.
"""

from std.ffi import (
    c_char,
    c_int,
    c_long,
    c_long_long,
    c_short,
    c_size_t,
    c_ulong,
    external_call,
)
from std.sys import exit

from abi_probe import (
    check_count,
    check_float,
    check_int,
    check_returned_int,
    check_size,
    reset,
)


# ===-----------------------------------------------------------------------===#
# The widths themselves
# ===-----------------------------------------------------------------------===#


def test_widths() -> Int:
    """Checks every C type alias is as wide here as the same type is in C.

    Runs before anything else, and it is the only thing in this file that
    catches a wrong width. Setting `c_long` to 64 bits on Windows and running
    the rest of this file leaves every value check passing, because the callee
    reads the low half of a slot that is eight bytes wide either way. This
    check fails on the spot.
    """
    var failures = check_size[c_char, "abi_size_c_char"]("c_char")
    failures += check_size[c_short, "abi_size_c_short"]("c_short")
    failures += check_size[c_int, "abi_size_c_int"]("c_int")
    failures += check_size[c_long, "abi_size_c_long"]("c_long")
    failures += check_size[c_long_long, "abi_size_c_long_long"]("c_long_long")
    failures += check_size[c_size_t, "abi_size_c_size_t"]("c_size_t")
    failures += check_size[Pointer[Int8, MutAnyOrigin], "abi_size_pointer"](
        "a pointer"
    )
    failures += check_size[Bool, "abi_size_bool"]("Bool")
    return failures


def test_char_signedness() -> Int:
    """Checks plain C `char` is signed here if it is signed in C.

    Not a width question but it lives with them, because it is the other thing
    the data model leaves open and the other thing that is decided by the target
    rather than by the language. It is signed on x86-64 Windows and Linux both.
    It is unsigned on ARM Linux, so this one will start earning its keep when
    somebody builds for arm64.
    """
    var theirs = Int(external_call["abi_char_is_signed", Int32]())
    comptime ours = 1 if c_char.dtype.is_signed() else 0
    if ours == theirs:
        return 0
    print("FAIL c_char is signed here:", ours == 1, "and in C:", theirs == 1)
    return 1


# ===-----------------------------------------------------------------------===#
# Values, once the widths agree
# ===-----------------------------------------------------------------------===#


def long_at(index: Int) -> Int64:
    """A distinct value per position that fits in 32 bits.

    Every value here has to survive a 32 bit `long`, so nothing goes near the
    64 bit range even on the platforms where it would fit. Testing that a
    Windows `long` cannot hold a large number is testing the C standard, not
    this compiler.
    """
    return Int64(100000 + index * 37)


def test_long() -> Int:
    """Six `long` arguments, all of them in registers."""
    reset()
    external_call["abi_long_x6", NoneType](
        c_long(long_at(0)),
        c_long(long_at(1)),
        c_long(long_at(2)),
        c_long(long_at(3)),
        c_long(long_at(4)),
        c_long(long_at(5)),
    )
    var failures = check_count("abi_long_x6", 6)
    for index in range(6):
        failures += check_int("abi_long_x6", index, long_at(index))
    return failures


def test_ulong() -> Int:
    """The unsigned twin, which has to be the same width as the signed one."""
    reset()
    external_call["abi_ulong_x6", NoneType](
        c_ulong(long_at(0)),
        c_ulong(long_at(1)),
        c_ulong(long_at(2)),
        c_ulong(long_at(3)),
        c_ulong(long_at(4)),
        c_ulong(long_at(5)),
    )
    var failures = check_count("abi_ulong_x6", 6)
    for index in range(6):
        failures += check_int("abi_ulong_x6", index, long_at(index))
    return failures


def test_long_long() -> Int:
    """`long long`, which is 64 bits on every platform in scope.

    Here as a control. If `long` fails and `long long` passes then the problem
    is the data model. If both fail then the problem is somewhere else and the
    data model is a red herring.
    """
    reset()
    external_call["abi_long_long_x6", NoneType](
        c_long_long(long_at(0)),
        c_long_long(long_at(1)),
        c_long_long(long_at(2)),
        c_long_long(long_at(3)),
        c_long_long(long_at(4)),
        c_long_long(long_at(5)),
    )
    var failures = check_count("abi_long_long_x6", 6)
    for index in range(6):
        failures += check_int("abi_long_long_x6", index, long_at(index))
    return failures


def test_long_mixed() -> Int:
    """`long` next to types whose width is the same everywhere.

    Not a width check, whatever it looks like. Mixing widths does not shift the
    neighbours on x86-64, because the slot is the same size either way. What
    this asks is whether a narrow argument between wide ones still consumes its
    own slot, which is a question about placement and belongs with the rest of
    the placement tests.
    """
    reset()
    external_call["abi_long_mixed", NoneType](
        c_long(long_at(0)),
        Int64(long_at(1)),
        c_long(long_at(2)),
        Int32(long_at(3)),
        c_long(long_at(4)),
        Int64(long_at(5)),
    )
    var failures = check_count("abi_long_mixed", 6)
    for index in range(6):
        failures += check_int("abi_long_mixed", index, long_at(index))
    return failures


def test_long_spill() -> Int:
    """Nine `long` arguments, so the last three go on the stack.

    A stack slot is eight bytes wide whatever is in it, so a 32 bit `long` still
    takes a whole one. A caller that packed two of them into one slot would put
    every argument after them somewhere else, and this is the only place in the
    suite where that packing would be visible.
    """
    reset()
    external_call["abi_long_x9", NoneType](
        c_long(long_at(0)),
        c_long(long_at(1)),
        c_long(long_at(2)),
        c_long(long_at(3)),
        c_long(long_at(4)),
        c_long(long_at(5)),
        c_long(long_at(6)),
        c_long(long_at(7)),
        c_long(long_at(8)),
    )
    var failures = check_count("abi_long_x9", 9)
    for index in range(9):
        failures += check_int("abi_long_x9", index, long_at(index))
    return failures


def test_long_negative() -> Int:
    """Negative `long` values, which is where extension shows up.

    A narrow signed value arrives in a register wider than itself and the bits
    above it are the caller's job. Positive values look identical whether the
    caller sign extends or zero extends, so this is the only shape of test that
    can tell the two apart.
    """
    reset()
    external_call["abi_long_negative", NoneType](
        c_long(-1), c_long(-2147483648), c_long(-70001)
    )
    var failures = check_count("abi_long_negative", 3)
    failures += check_int("abi_long_negative", 0, -1)
    failures += check_int("abi_long_negative", 1, -2147483648)
    failures += check_int("abi_long_negative", 2, -70001)
    return failures


def test_long_returns() -> Int:
    """Coming back the other way. Each probe adds one to what it was given."""
    var failures = check_returned_int(
        "abi_ret_long",
        Int64(external_call["abi_ret_long", c_long](c_long(long_at(0)))),
        long_at(0) + 1,
    )
    failures += check_returned_int(
        "abi_ret_ulong",
        Int64(external_call["abi_ret_ulong", c_ulong](c_ulong(long_at(1)))),
        long_at(1) + 1,
    )
    failures += check_returned_int(
        "abi_ret_long_long",
        Int64(
            external_call["abi_ret_long_long", c_long_long](
                c_long_long(long_at(2))
            )
        ),
        long_at(2) + 1,
    )
    return failures


# ===-----------------------------------------------------------------------===#
# Bool
# ===-----------------------------------------------------------------------===#


def bool_at(index: Int) -> Bool:
    """Alternating, so a run of all true or all false cannot pass by accident."""
    return index % 2 == 0


def expected_bool_at(index: Int) -> Int64:
    """The same pattern as an integer, which is what the probes record."""
    return 1 if bool_at(index) else 0


def test_bool() -> Int:
    """Six bools in a row."""
    reset()
    external_call["abi_bool_x6", NoneType](
        bool_at(0),
        bool_at(1),
        bool_at(2),
        bool_at(3),
        bool_at(4),
        bool_at(5),
    )
    var failures = check_count("abi_bool_x6", 6)
    for index in range(6):
        failures += check_int("abi_bool_x6", index, expected_bool_at(index))
    return failures


def test_bool_mixed() -> Int:
    """Bools between wider arguments, including one that wants a float register.

    A one byte argument still takes a whole register, and the float in position
    four still takes an SSE register on Linux and the fourth register slot on
    Windows. The bools around it are what shows if either of those went wrong.
    """
    reset()
    external_call["abi_bool_mixed", NoneType](
        bool_at(0),
        Int64(long_at(1)),
        bool_at(2),
        Float64(3.5),
        bool_at(4),
        Int32(long_at(5)),
    )
    var failures = check_count("abi_bool_mixed", 6)
    failures += check_int("abi_bool_mixed", 0, expected_bool_at(0))
    failures += check_int("abi_bool_mixed", 1, long_at(1))
    failures += check_int("abi_bool_mixed", 2, expected_bool_at(2))
    failures += check_float("abi_bool_mixed", 3, 3.5)
    failures += check_int("abi_bool_mixed", 4, expected_bool_at(4))
    failures += check_int("abi_bool_mixed", 5, long_at(5))
    return failures


def test_bool_spill() -> Int:
    """Bools past the register file, where a packed slot would be visible."""
    reset()
    external_call["abi_bool_spill", NoneType](
        Int64(long_at(0)),
        Int64(long_at(1)),
        Int64(long_at(2)),
        Int64(long_at(3)),
        Int64(long_at(4)),
        bool_at(5),
        bool_at(6),
        bool_at(7),
    )
    var failures = check_count("abi_bool_spill", 8)
    for index in range(5):
        failures += check_int("abi_bool_spill", index, long_at(index))
    for index in range(5, 8):
        failures += check_int("abi_bool_spill", index, expected_bool_at(index))
    return failures


def test_bool_returns() -> Int:
    """A returned bool, which the probe flips so neither answer is the input."""
    var failures = 0
    if external_call["abi_ret_bool", Bool](True):
        print("FAIL abi_ret_bool returned True for True, expected False")
        failures += 1
    if not external_call["abi_ret_bool", Bool](False):
        print("FAIL abi_ret_bool returned False for False, expected True")
        failures += 1
    return failures


def test_bool_raw_byte() -> Int:
    """Checks true arrives as the byte 1 and not as some other non zero byte.

    The ABI says a bool argument is 0 or 1 and says nothing about the bits above
    it, so a caller that sends 0xff for true is sending something the callee is
    entitled to refuse. This is the weakest check in the file, because the C
    compiler is allowed to normalise the value on the way in and hide a bad
    caller. A failure here means there is definitely a bug. A pass means there
    is probably not one.
    """
    var failures = check_returned_int(
        "abi_bool_raw_byte true",
        Int64(external_call["abi_bool_raw_byte", Int32](True)),
        1,
    )
    failures += check_returned_int(
        "abi_bool_raw_byte false",
        Int64(external_call["abi_bool_raw_byte", Int32](False)),
        0,
    )
    return failures


def main():
    var failures = test_widths()
    failures += test_char_signedness()
    failures += test_long()
    failures += test_ulong()
    failures += test_long_long()
    failures += test_long_mixed()
    failures += test_long_spill()
    failures += test_long_negative()
    failures += test_long_returns()
    failures += test_bool()
    failures += test_bool_mixed()
    failures += test_bool_spill()
    failures += test_bool_returns()
    failures += test_bool_raw_byte()

    if failures != 0:
        print(failures, "checks failed")
        exit(1)

    print("C type width conformance passed")
