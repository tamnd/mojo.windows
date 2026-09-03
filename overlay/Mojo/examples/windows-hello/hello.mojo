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

# The smallest Mojo program that is worth cross building to Windows, and the one
# to reach for first when something on that path breaks. It uses print and one
# compile time predicate and nothing else, so a failure here is a failure of the
# toolchain rather than of anything the program asked for.

from std.sys.info import CompilationTarget


def main():
    print("Hello from Mojo")
    print("built for Windows:", CompilationTarget.is_windows())
