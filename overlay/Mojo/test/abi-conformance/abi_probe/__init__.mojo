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
"""The Mojo side of the ABI conformance probe.

Wraps the accessors in probe.c and gives the tests a way to say what they
expected. Everything here is deliberately dull. A test harness that is itself
interesting is a test harness that gets blamed for its own failures, and the
whole value of this suite is that a failure means the compiler is wrong.
"""

from std.ffi import external_call


def reset():
    """Forgets every argument recorded so far. Call it before each probe."""
    external_call["abi_probe_reset", NoneType]()


def count() -> Int:
    """How many arguments the last probe recorded."""
    return Int(external_call["abi_probe_count", Int32]())


def slot_int(index: Int) -> Int64:
    """The integer argument that arrived in position `index`, counting from 0."""
    return external_call["abi_probe_int", Int64](Int32(index))


def slot_float(index: Int) -> Float64:
    """The floating point argument that arrived in position `index`."""
    return external_call["abi_probe_float", Float64](Int32(index))


def check_count(probe: StaticString, want: Int) -> Int:
    """Checks the probe recorded as many arguments as it has parameters.

    Worth checking separately, because a probe that recorded the wrong number of
    arguments has gone wrong before any individual value is worth looking at.

    Args:
        probe: The name of the probe, used in the failure message.
        want: The number of arguments the probe should have recorded.

    Returns:
        1 if the check failed, 0 if it passed.
    """
    var got = count()
    if got == want:
        return 0
    print("FAIL", probe, "recorded", got, "arguments, expected", want)
    return 1


def check_int(probe: StaticString, index: Int, want: Int64) -> Int:
    """Checks the integer argument in position `index` arrived intact.

    Args:
        probe: The name of the probe, used in the failure message.
        index: The argument position, counting from 0.
        want: The value the caller passed.

    Returns:
        1 if the check failed, 0 if it passed.
    """
    var got = slot_int(index)
    if got == want:
        return 0
    print(
        "FAIL",
        probe,
        "argument",
        index + 1,
        "arrived as",
        got,
        "expected",
        want,
    )
    return 1


def check_float(probe: StaticString, index: Int, want: Float64) -> Int:
    """Checks the floating point argument in position `index` arrived intact.

    Compared for exact equality on purpose. Every value the suite passes is a
    small whole number, so it survives the trip unchanged unless something went
    wrong, and a tolerance here would hide the case where an argument lands in
    the wrong register and happens to be close.

    Args:
        probe: The name of the probe, used in the failure message.
        index: The argument position, counting from 0.
        want: The value the caller passed.

    Returns:
        1 if the check failed, 0 if it passed.
    """
    var got = slot_float(index)
    if got == want:
        return 0
    print(
        "FAIL",
        probe,
        "argument",
        index + 1,
        "arrived as",
        got,
        "expected",
        want,
    )
    return 1


def check_returned_int(probe: StaticString, got: Int64, want: Int64) -> Int:
    """Checks a probe returned the integer it was supposed to.

    Args:
        probe: The name of the probe, used in the failure message.
        got: What the probe returned.
        want: What it should have returned.

    Returns:
        1 if the check failed, 0 if it passed.
    """
    if got == want:
        return 0
    print("FAIL", probe, "returned", got, "expected", want)
    return 1


def check_returned_float(probe: StaticString, got: Float64, want: Float64) -> Int:
    """Checks a probe returned the floating point value it was supposed to.

    Args:
        probe: The name of the probe, used in the failure message.
        got: What the probe returned.
        want: What it should have returned.

    Returns:
        1 if the check failed, 0 if it passed.
    """
    if got == want:
        return 0
    print("FAIL", probe, "returned", got, "expected", want)
    return 1


def check_returned_int_field(
    probe: StaticString, field: Int, got: Int64, want: Int64
) -> Int:
    """Checks one integer field of a returned struct.

    Args:
        probe: The name of the probe, used in the failure message.
        field: The field position, counting from 0.
        got: What came back in that field.
        want: What should have.

    Returns:
        1 if the check failed, 0 if it passed.
    """
    if got == want:
        return 0
    print("FAIL", probe, "returned field", field, "as", got, "expected", want)
    return 1


def check_returned_float_field(
    probe: StaticString, field: Int, got: Float64, want: Float64
) -> Int:
    """Checks one floating point field of a returned struct.

    Args:
        probe: The name of the probe, used in the failure message.
        field: The field position, counting from 0.
        got: What came back in that field.
        want: What should have.

    Returns:
        1 if the check failed, 0 if it passed.
    """
    if got == want:
        return 0
    print("FAIL", probe, "returned field", field, "as", got, "expected", want)
    return 1
