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

from std.os.path import join, normcase
from std.sys.info import CompilationTarget

from std.testing import TestSuite, assert_equal, assert_not_equal, assert_true


def test_leaves_a_unix_path_alone() raises:
    comptime if CompilationTarget.is_windows():
        return

    # Case is part of a name on Unix and a slash is the only separator, so
    # there is nothing here to put into any other form.
    assert_equal(normcase("/usr/lib/File.TXT"), "/usr/lib/File.TXT")
    assert_equal(normcase("Relative/Path"), "Relative/Path")
    assert_equal(normcase(""), "")
    assert_equal(normcase("a\\b"), "a\\b")


def test_case_and_separators() raises:
    comptime if CompilationTarget.is_windows():
        assert_equal(normcase("C:\\Users\\Name"), "c:\\users\\name")
        assert_equal(normcase("C:/Users/Name"), "c:\\users\\name")
        assert_equal(
            normcase("\\\\Server\\Share\\Dir"), "\\\\server\\share\\dir"
        )
        assert_equal(normcase(""), "")


def test_two_spellings_of_one_path() raises:
    """The reason this function exists, rather than what it does."""
    comptime if CompilationTarget.is_windows():
        # Every one of these is the same file and no two of them are the same
        # string, which is what makes comparing paths as text wrong.
        var written = "C:/Users/Name/file.TXT"
        var stored = "c:\\Users\\name\\File.txt"
        assert_not_equal(written, stored)
        assert_equal(normcase(written), normcase(stored))
        return

    # On Unix these really are two files and the answer has to stay no.
    assert_not_equal(normcase("a/File.txt"), normcase("a/file.txt"))


def test_only_case_and_separators() raises:
    """What this deliberately does not do.

    It is not a normalisation in any other sense, and a caller that reads it as
    one gets a wrong answer quietly. Two paths that name the same file can come
    out of it different.
    """
    assert_true(normcase(join("a", ".", "b")) != normcase(join("a", "b")))
    assert_true(normcase(join("a", "b", "..", "c")) != normcase(join("a", "c")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
