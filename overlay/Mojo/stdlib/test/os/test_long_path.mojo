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

# A tree deep enough that the path to the bottom of it is past the classic
# Windows limit of 260 characters, built out of names that are individually
# unremarkable. That is the shape the limit actually turns up in: nothing here
# is a long name, there are just several of them.
comptime _LEVEL = "a_directory_with_an_unremarkable_name"
comptime _LEVELS = 9
comptime _CONTENT = "the file at the bottom"


def _deep_path() -> String:
    var path = String(_LEVEL)
    for _ in range(_LEVELS - 1):
        path = join(path, _LEVEL)
    return path^


def _remove_tree(path: String) raises:
    """Takes the tree down a level at a time from the bottom.

    `removedirs` would do this, and is not used because it stops at the first
    directory it cannot remove and says nothing, which would let this test pass
    while leaving most of the tree behind for the next one.
    """
    var remaining = path
    for _ in range(_LEVELS):
        std.os.rmdir(remaining)
        remaining = std.os.path.split(remaining)[0]


def test_a_path_past_the_classic_limit() raises:
    """Creating, writing, reading and removing below 260 characters of path.

    Every one of these is a separate call into the platform and they do not all
    go through the same one, so the point of doing all of them is that the path
    is put into whatever form it needs on the way to each.
    """
    var deep = _deep_path()

    # Worth asserting rather than trusting the arithmetic above, because a test
    # that stopped being long enough would keep passing and stop meaning
    # anything.
    assert_true(deep.byte_length() > 260)

    assert_false(exists(deep))
    std.os.makedirs(deep)
    assert_true(isdir(deep))

    var file = join(deep, "file.txt")
    with open(file, "w") as handle:
        handle.write(_CONTENT)

    assert_true(isfile(file))
    assert_equal(getsize(file), _CONTENT.byte_length())

    with open(file, "r") as handle:
        assert_equal(handle.read(), _CONTENT)

    var entries = std.os.listdir(deep)
    assert_equal(len(entries), 1)
    assert_equal(entries[0], "file.txt")

    std.os.remove(file)
    assert_false(exists(file))

    _remove_tree(deep)
    assert_false(exists(_LEVEL))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
