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
from std.os.env import getenv, setenv, unsetenv
from std.os.path import expanduser, join
from std.sys.info import CompilationTarget

from std.testing import TestSuite, assert_equal

# Which variable holds the home directory. Windows has no password database to
# look a user up in, so the answer comes out of the environment there and the
# variable is not the one Unix uses.
comptime _HOME_VAR = "USERPROFILE" if CompilationTarget.is_windows() else "HOME"


def get_user_path() -> String:
    comptime if CompilationTarget.is_windows():
        return "C:\\Users\\user"
    return "/home/user"


def get_current_home() -> String:
    return getenv(_HOME_VAR)


def set_home(path: String) raises:
    _ = setenv(_HOME_VAR, path)


def test_expanduser() raises:
    var user_path = get_user_path()
    var original_home = get_current_home()
    set_home(user_path)

    # Single `~`
    assert_equal(user_path, expanduser("~"))

    # Path with home directory
    assert_equal(join(user_path, "folder"), expanduser(join("~", "folder")))

    # Path with trailing slash
    assert_equal(
        join(user_path, "folder") + std.os.sep,
        expanduser(join("~", "folder") + std.os.sep),
    )

    # Path without user home directory
    assert_equal("/usr/bin", expanduser("/usr/bin"))

    # Relative path
    assert_equal("../folder", expanduser("../folder"))

    # Empty string
    assert_equal("", expanduser(""))

    # Path with multiple tildes
    assert_equal(join(user_path, "~folder"), expanduser(join("~", "~folder")))

    set_home(original_home)


# `HOMEDRIVE` and `HOMEPATH` are the fallback when `USERPROFILE` is missing,
# and a path with no home to put in it comes back the way it went in.
def test_expanduser_windows_home_drive() raises:
    comptime if CompilationTarget.is_windows():
        var original_home = getenv("USERPROFILE")
        var original_drive = getenv("HOMEDRIVE")
        var original_path = getenv("HOMEPATH")

        _ = unsetenv("USERPROFILE")
        _ = setenv("HOMEDRIVE", "C:")
        _ = setenv("HOMEPATH", "\\Users\\user")
        assert_equal("C:\\Users\\user", expanduser("~"))

        # Nothing to expand from, so the path is handed back untouched rather
        # than turned into something that points at the wrong place.
        _ = unsetenv("HOMEDRIVE")
        _ = unsetenv("HOMEPATH")
        assert_equal("~", expanduser("~"))
        assert_equal("~\\folder", expanduser("~\\folder"))

        _ = setenv("USERPROFILE", original_home)
        _ = setenv("HOMEDRIVE", original_drive)
        _ = setenv("HOMEPATH", original_path)


# `~other` is guesswork everywhere, and on Windows the guess is that profile
# directories sit side by side under one parent and are named after their user.
def test_expanduser_windows_other_user() raises:
    comptime if CompilationTarget.is_windows():
        var original_home = getenv("USERPROFILE")
        var original_user = getenv("USERNAME")

        _ = setenv("USERPROFILE", "C:\\Users\\user")
        _ = setenv("USERNAME", "user")
        assert_equal("C:\\Users\\other", expanduser("~other"))
        assert_equal("C:\\Users\\other\\dir", expanduser("~other\\dir"))

        # The current user's own home does not sit under a directory named
        # after them, so the guess has nothing to stand on and is not made.
        _ = setenv("USERPROFILE", "D:\\somewhere\\else")
        assert_equal("~other", expanduser("~other"))

        _ = setenv("USERPROFILE", original_home)
        _ = setenv("USERNAME", original_user)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
