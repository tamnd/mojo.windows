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

from std.collections import List
from std.os.path import exists
from std.os import Process, setenv
from std.os.process import Pipe, _quote_for_windows, _windows_command_line
from std.sys import CompilationTarget

from std.testing import (
    assert_false,
    assert_raises,
    assert_true,
    assert_equal,
)

# ===----------------------------------------------------------------------=== #
# The programs to spawn
# ===----------------------------------------------------------------------=== #
#
# None of `echo`, `sleep` or `printenv` is a program on Windows. Two of them are
# builtins of the command interpreter and the third has no equivalent at all, so
# the helpers below pick something per platform and the tests themselves say
# what they want rather than which program provides it.
#
# The output has to come out the same on both, because the checks in this file
# are one set of CHECK lines and there is no way to write those twice.


def _run_echo(words: List[String]) raises -> Process:
    """Spawns something that prints `words` on one line, separated by spaces.

    `echo` puts a space between its arguments and so does the `echo` builtin of
    `cmd`, so the words go through as they are on either side. They are passed
    as separate arguments rather than as one string with spaces in it because
    `cmd` would print the quotes that a string with spaces in it needs.
    """
    comptime if CompilationTarget.is_windows():
        var argv: List[String] = ["/c", "echo"]
        for var word in words:
            argv.append(word^)
        return Process.run("cmd", argv)
    else:
        return Process.run("echo", words)


def _run_sleep() raises -> Process:
    """Spawns something that stays alive long enough to be killed."""
    comptime if CompilationTarget.is_windows():
        # There is no `sleep`. Sending pings a second apart to the loopback
        # address is how this is done on Windows, and unlike `timeout` it does
        # not want to read a key from a console, so it still works when a test
        # runner has redirected the input.
        return Process.run("ping", ["-n", "60", "127.0.0.1"])
    else:
        return Process.run("sleep", ["60"])


def _run_exit(code: Int) raises -> Process:
    """Spawns something that exits with `code` and does nothing else."""
    comptime if CompilationTarget.is_windows():
        return Process.run("cmd", ["/c", "exit", String(code)])
    else:
        return Process.run("sh", ["-c", String("exit ", code)])


def _run_env_probe(name: String) raises -> Process:
    """Spawns something that exits zero when `name` is set in its environment.
    """
    comptime if CompilationTarget.is_windows():
        # `set NAME` is the interpreter's own way of asking, and it exits 1 when
        # there is nothing by that name. It matches on a prefix rather than on
        # the whole name, which is close enough for a name nothing else shares.
        return Process.run("cmd", ["/c", "set", name])
    else:
        return Process.run("printenv", [name])


# ===----------------------------------------------------------------------=== #
# Tests
# ===----------------------------------------------------------------------=== #


def test_pipe() raises:
    var p = Pipe()
    var s = Array[UInt8, 5](fill=0)
    p.write_bytes("hello".as_bytes())
    assert_equal(p.read_bytes(Span(s)), 5)
    assert_true(Span(s) == "hello".as_bytes())
    p.set_output_only()
    with assert_raises():
        _ = p.read_bytes(Span(s))


def test_process_run() raises:
    print("== test_process_run")
    # CHECK-LABEL: == test_process_run
    # CHECK-NEXT: == TEST_ECHO
    _ = _run_echo(["==", "TEST_ECHO"])


def test_process_wait() raises:
    print("== test_process_wait")
    var p = _run_echo(["==", "TEST_WAIT"])
    assert_true(p.wait().has_exited())
    assert_equal(p.wait().exit_code.value(), 0)
    assert_false(p.kill())


def test_process_exit_code() raises:
    print("== test_process_exit_code")
    var p = _run_exit(3)
    var status = p.wait()
    assert_true(status.has_exited())
    assert_equal(status.exit_code.value(), 3)


def test_process_kill() raises:
    print("== test_process_kill")
    var p = _run_sleep()
    assert_true(p.kill())
    assert_true(p.wait().has_exited())


def test_process_run_missing() raises:
    print("== test_process_run_missing")
    # CHECK-LABEL: == test_process_run_missing
    # CHECK-NEXT: Failed to execute ThIsFiLeCoUlDNoTPoSsIbLlYExIsT.NoTAnExTeNsIoN
    var missing_executable_file = (
        "ThIsFiLeCoUlDNoTPoSsIbLlYExIsT.NoTAnExTeNsIoN"
    )

    # verify that the test file does not exist before starting the test
    assert_false(
        exists(missing_executable_file),
        "Unexpected file '" + missing_executable_file + "' it should not exist",
    )

    try:
        _ = Process.run(missing_executable_file, List[String]())
    except e:
        print(e)
        # The check above stops at the name because the rest of the line is
        # whatever the system had to say, and the two systems say it
        # differently: an errno on one side, a sentence out of the system
        # message table on the other. The errno is worth pinning down here. The
        # sentence is not, because it comes back in whichever language the
        # machine was installed in.
        comptime if not CompilationTarget.is_windows():
            assert_true("EINT error code: 2" in String(e))

    with assert_raises():
        _ = Process.run(missing_executable_file, List[String]())


def test_process_inherits_env() raises:
    print("== test_process_inherits_env")
    # Set a unique env var and verify the child process inherits it.
    _ = setenv("_MOJO_TEST_ENV_INHERIT", "inherited_ok")

    var p = _run_env_probe("_MOJO_TEST_ENV_INHERIT")
    var status = p.wait()
    assert_equal(status.exit_code.value(), 0)


def test_quote_for_windows() raises:
    """One argument, spelled for a Windows command line.

    Windows hands a process a single string and every process splits it up
    again itself, so this has to be exactly right or an argument arrives as two
    arguments, or as one with the wrong characters in it. The cases below are
    the ones that are easy to get wrong. Each has a comment giving the input and
    the result as plain text, because the escaping Mojo needs to write them down
    makes the literals hard to read.

    This runs everywhere, not only on Windows, because it is a string function
    and nothing about checking it needs the operating system it is written for.
    """
    # plain -> plain. Nothing to do without a space, a tab or a quote.
    assert_equal(_quote_for_windows("plain"), "plain")

    # a\b -> a\b. A backslash on its own is not special.
    assert_equal(_quote_for_windows("a\\b"), "a\\b")

    # a\ -> a\. Still not special at the end, as long as no quote follows.
    assert_equal(_quote_for_windows("a\\"), "a\\")

    #  -> "". The empty argument needs the quotes or there is nothing there to
    # split off at all, and the caller ends up passing one argument fewer than
    # it thinks.
    assert_equal(_quote_for_windows(""), '""')

    # a b -> "a b"
    assert_equal(_quote_for_windows("a b"), '"a b"')

    # a<tab>b -> "a<tab>b". A tab separates arguments the same way a space does.
    assert_equal(_quote_for_windows("a\tb"), '"a\tb"')

    # a"b -> "a\"b"
    assert_equal(_quote_for_windows('a"b'), '"a\\"b"')

    # " -> "\""
    assert_equal(_quote_for_windows('"'), '"\\""')

    # \" -> "\\\"". One backslash in front of a quote becomes three, because
    # the rule is that 2n+1 of them followed by a quote mean n backslashes and
    # a quote that is part of the argument.
    assert_equal(_quote_for_windows('\\"'), '"\\\\\\""')

    # C:\Program Files\x -> "C:\Program Files\x". The backslashes are left
    # alone because none of them is in front of a quote.
    assert_equal(
        _quote_for_windows("C:\\Program Files\\x"), '"C:\\Program Files\\x"'
    )

    # two words\ -> "two words\\". The run at the end lands in front of the
    # closing quote, which counts as being in front of a quote, so it doubles.
    # Getting this wrong is what turns a directory argument ending in a
    # separator into a quote that never closes.
    assert_equal(_quote_for_windows("two words\\"), '"two words\\\\"')


def test_windows_command_line() raises:
    """The whole line, program first, which is what CreateProcessW is handed."""
    assert_equal(
        _windows_command_line("C:\\bin\\tool.exe", ["--out", "a b", ""]),
        'C:\\bin\\tool.exe --out "a b" ""',
    )
    assert_equal(
        _windows_command_line("C:\\Program Files\\tool.exe", List[String]()),
        '"C:\\Program Files\\tool.exe"',
    )


def main() raises:
    test_process_run()
    test_process_run_missing()
    test_process_wait()
    test_process_exit_code()
    test_process_kill()
    test_pipe()
    test_process_inherits_env()
    test_quote_for_windows()
    test_windows_command_line()
