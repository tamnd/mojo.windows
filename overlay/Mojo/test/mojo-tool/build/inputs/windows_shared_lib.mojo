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
#
# Input for the shared library runs in ../windows_target_link_line.mojo. A
# shared library is not allowed to have a `main`, and the file name is what the
# default output name is derived from, so this cannot just be the test file.


@export
def add_one(x: Int) abi("C") -> Int:
    return x + 1
