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

# RUN: %bare-mojo build --target-triple=x86_64-unknown-linux-gnu -D EXPECT_LINUX --emit=llvm %s -o /dev/null
# RUN: %bare-mojo build --target-triple=aarch64-unknown-linux-gnu -D EXPECT_LINUX --emit=llvm %s -o /dev/null
# RUN: %bare-mojo build --target-triple=arm64-apple-macosx -D EXPECT_MACOS --emit=llvm %s -o /dev/null
# RUN: %bare-mojo build --target-triple=x86_64-apple-darwin -D EXPECT_MACOS --emit=llvm %s -o /dev/null
# RUN: %bare-mojo build --target-triple=x86_64-pc-windows-msvc -D EXPECT_WINDOWS --emit=llvm %s -o /dev/null
# RUN: %bare-mojo build --target-triple=x86_64-pc-windows-gnu -D EXPECT_WINDOWS --emit=llvm %s -o /dev/null

# These predicates read the OS out of the target triple, so this test compiles
# for six triples from whatever machine it runs on rather than checking the host.
# Both macOS spellings are here because `is_macos()` matches a list of two, and
# both Windows environments are here because the environment field is not the OS
# field and neither predicate should be reading it.

from std.sys import is_defined
from std.sys.info import CompilationTarget, platform_map


def main():
    comptime expect_linux = is_defined["EXPECT_LINUX"]()
    comptime expect_macos = is_defined["EXPECT_MACOS"]()
    comptime expect_windows = is_defined["EXPECT_WINDOWS"]()

    comptime assert (
        CompilationTarget.is_linux() == expect_linux
    ), "is_linux() disagrees with the target triple"
    comptime assert (
        CompilationTarget.is_macos() == expect_macos
    ), "is_macos() disagrees with the target triple"
    comptime assert (
        CompilationTarget.is_windows() == expect_windows
    ), "is_windows() disagrees with the target triple"

    # Exactly one of the three is true for any of the triples above, and that is
    # the property the rest of the library leans on when it writes an if and an
    # else instead of three branches. Before there was a Windows predicate the
    # else in those pairs meant Linux, and a Windows target took it silently.
    comptime assert (
        Int(CompilationTarget.is_linux())
        + Int(CompilationTarget.is_macos())
        + Int(CompilationTarget.is_windows())
        == 1
    ), "exactly one OS predicate must be true for a supported target"

    # `platform_map` is the shape the library is supposed to use when it needs a
    # different constant per OS, because the arm that is missing is a compile
    # time error rather than a wrong answer. Check that the Windows arm is
    # reachable and that adding it did not move the other two.
    comptime expected = 3 if expect_windows else (2 if expect_macos else 1)
    comptime mapped = platform_map[
        "test_os_predicates", linux=1, macos=2, windows=3
    ]()
    comptime assert (
        mapped == expected
    ), "platform_map() picked the wrong arm for the target triple"
