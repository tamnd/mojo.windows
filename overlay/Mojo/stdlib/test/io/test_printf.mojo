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

from std.io.io import _printf

from std.testing import assert_equal

# `_printf` is what `debug_assert` reports through, so it is on the path a
# program takes when something has already gone wrong and there is nothing else
# left to tell anyone with. Nothing checked it until now, on any platform.
#
# The output goes to a descriptor rather than to anything this program can read
# back, so the checking is done by FileCheck rather than by an assertion.


def test_printf_types() raises:
    print("== test_printf_types")
    # CHECK-LABEL: == test_printf_types
    # CHECK-NEXT: string 42 -7 3.5 c
    _printf["%s %llu %d %.1f %c\n"](
        "string".as_c_string_slice(),
        UInt(42),
        Int32(-7),
        Float64(3.5),
        Int32(ord("c")),
    )


def test_printf_empty() raises:
    print("== test_printf_empty")
    # CHECK-LABEL: == test_printf_empty
    # CHECK-NEXT: after the empty one
    _printf[""]()
    _printf["after the empty one\n"]()


def test_printf_longer_than_the_buffer() raises:
    """A message that does not fit in the buffer.

    Formatting happens into a fixed buffer and nothing on this path allocates,
    so a message longer than the buffer loses its tail. What matters is that the
    part that did fit still comes out, because the alternative, and what the
    obvious reading of `snprintf`'s return value gives you, is nothing at all.
    """
    print("== test_printf_longer_than_the_buffer")
    var body = String("x") * 5000
    assert_equal(body.byte_length(), 5000)

    # CHECK-LABEL: == test_printf_longer_than_the_buffer
    # CHECK-NEXT: <xxxxxxxxxx{{x+}}
    # CHECK-NOT: 5000
    _printf["<%s> %llu\n"](body.as_c_string_slice(), UInt(body.byte_length()))


def main() raises:
    test_printf_types()
    test_printf_empty()
    test_printf_longer_than_the_buffer()
