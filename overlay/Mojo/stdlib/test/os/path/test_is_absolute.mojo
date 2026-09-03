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

from std.os.path import is_absolute
from std.sys.info import CompilationTarget

from std.testing import TestSuite, assert_false, assert_true


def test_is_absolute() raises:
    comptime if CompilationTarget.is_windows():
        # A leading separator is not enough on Windows. It picks the top of a
        # drive without saying which drive, so resolving it still needs to know
        # where the process is, which is what everybody means by relative.
        assert_true(is_absolute("C:\\"))
        assert_true(is_absolute("C:\\foo"))
        assert_true(is_absolute("c:/foo/bar"))

        assert_false(is_absolute(""))
        assert_false(is_absolute("foo\\bar"))
        assert_false(is_absolute("/"))
        assert_false(is_absolute("/foo"))
        assert_false(is_absolute("\\foo"))

        # A drive with no root is relative to the current directory on that
        # drive, which is a real thing on Windows and catches people out.
        assert_false(is_absolute("C:"))
        assert_false(is_absolute("C:foo"))
        return

    assert_true(is_absolute("/"))
    assert_true(is_absolute("/foo"))
    assert_true(is_absolute("/foo/bar"))

    assert_false(is_absolute(""))
    assert_false(is_absolute("foo/bar"))


# Two leading separators is a share or a device, and both name one place.
def test_is_absolute_windows_unc() raises:
    comptime if CompilationTarget.is_windows():
        assert_true(is_absolute("\\\\server\\share"))
        assert_true(is_absolute("\\\\server\\share\\dir"))
        assert_true(is_absolute("//server/share/dir"))
        assert_true(is_absolute("\\\\?\\C:\\foo"))
        assert_true(is_absolute("\\\\?\\UNC\\server\\share"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
