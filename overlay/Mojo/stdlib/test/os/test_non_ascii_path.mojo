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
from std.os.path import exists, getsize, isdir, isfile, join

from std.testing import TestSuite, assert_equal, assert_false, assert_true

# Names with characters outside ASCII in them, going to the filesystem and
# coming back.
#
# On Unix a path is bytes and none of this is interesting. On Windows the
# filesystem stores UTF-16, every name handed to the platform is converted on
# the way out and converted back on the way in, and there are two ways for that
# to go wrong. A narrow call encodes the name in the machine's code page, which
# has no room for most of these characters and replaces them with question
# marks, so the file is created under a name nobody asked for. And a conversion
# that treats UTF-16 as one code unit per character loses anything above the
# basic plane, which is why one of the names below is an emoji: it is a
# surrogate pair, so a length computed in the wrong units is off by one and the
# name comes back truncated or with half a character on the end.
#
# The literals are also the test. If the source file were read in the wrong
# encoding somewhere between here and the compiler, the byte lengths asserted
# below would not match, so a build that mangles them fails here rather than
# producing a program that quietly disagrees with its own source.
comptime _DIR = "café-日本"
comptime _FILE = "naïve-🦋.txt"
comptime _CONTENT = "grüße from the file, 日本語 and 🦋"


def test_the_literals_are_utf8() raises:
    """Twelve bytes for seven characters and fifteen for twelve.

    Nothing about the filesystem here. This is the check that the rest of the
    file is testing what it says it is.
    """
    assert_equal(_DIR.byte_length(), 12)
    assert_equal(_FILE.byte_length(), 15)


def test_a_path_with_characters_outside_ascii() raises:
    """Creating, writing, reading, listing and removing under such a name.

    Each of these is a separate call into the platform and they do not all go
    through the same one, so doing all of them is the point: the name has to
    survive every conversion on the way out and the one on the way back.
    """
    assert_false(exists(_DIR))
    std.os.mkdir(_DIR)
    assert_true(isdir(_DIR))

    var file = join(_DIR, _FILE)
    with open(file, "w") as handle:
        handle.write(_CONTENT)

    assert_true(isfile(file))
    assert_equal(getsize(file), _CONTENT.byte_length())

    with open(file, "r") as handle:
        assert_equal(handle.read(), _CONTENT)

    # The direction that a write alone does not check. This name was produced
    # by the platform rather than handed to it, so it went through the
    # conversion the other way round.
    var entries = std.os.listdir(_DIR)
    assert_equal(len(entries), 1)
    assert_equal(entries[0], _FILE)

    std.os.remove(file)
    assert_false(exists(file))

    std.os.rmdir(_DIR)
    assert_false(exists(_DIR))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
