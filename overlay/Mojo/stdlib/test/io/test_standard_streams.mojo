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

from std.os import remove
from std.os.path import join
from std.sys._fd import (
    _O_BINARY,
    fd_close,
    fd_dup,
    fd_dup2,
    fd_set_binary_mode,
)
from std.sys.info import CompilationTarget
from std.tempfile import gettempdir

from std.testing import TestSuite, assert_equal


def test_stdout_writes_the_bytes_it_was_given() raises:
    """Points stdout at a file and checks nothing was rewritten on the way.

    The byte that matters is the newline. The Windows C runtime opens the
    standard streams in text mode, and text mode turns a newline on the way out
    into a carriage return and a newline, which is neither what `print` wrote
    nor what anything comparing the output is going to expect.
    """
    var temp_dir = gettempdir()
    if not temp_dir:
        raise Error("no temporary directory to write into")
    var path = join(temp_dir.value(), "mojo_standard_streams_check.txt")

    var capture = open(path, "w")
    var saved = fd_dup(1)

    # Nothing between here and the restore below is allowed to fail, because
    # its complaint would go into the file being measured rather than to
    # whoever is reading the test output.
    _ = fd_dup2(FileDescriptor(capture).value, 1)
    print("a")
    _ = fd_dup2(saved, 1)
    _ = fd_close(saved)

    capture.close()

    var reader = open(path, "r")
    var written = reader.read()
    reader.close()
    remove(path)

    assert_equal(written, "a\n")


def test_standard_streams_are_in_binary_mode() raises:
    """Asks the three descriptors what mode they are in, without changing it.

    `_setmode` hands back the mode the descriptor was in before the call, so
    setting it to binary and looking at the answer is a question and not an
    edit. Anything other than binary here means
    `_set_standard_streams_to_binary_mode` in `builtin/_startup.mojo` did not
    run, or ran somewhere the executable cannot see, which is the failure worth
    catching: it would otherwise show up much later, as output that does not
    match on a test that has nothing to do with streams.
    """
    comptime if CompilationTarget.is_windows():
        for fd in range(3):
            assert_equal(fd_set_binary_mode(fd), _O_BINARY)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
