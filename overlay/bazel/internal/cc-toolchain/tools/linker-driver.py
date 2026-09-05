#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
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
##===----------------------------------------------------------------------===##
"""Drives the link, and everything that has to happen either side of it.

This was a bash script. See multi-platform-clang.py for why it is Python now and
why the interpreter is the system one. The rewriting this file does to the link
line for Windows is a good deal easier to read as a loop over a list than as
bash array index arithmetic, which was the other reason to start with this one.
"""

import os
import platform
import subprocess
import sys
from typing import NamedTuple

ARCHIVE_PREFIX = "+http_archive+clang-"


class Options(NamedTuple):
    """The --modular- arguments, split away from the ones clang gets."""

    ifs_input: str
    ifs_output: str
    dsym_path: str
    binary_path: str
    linker_args: list[str]


# What an executable in the clang archive is called on this machine. The archive
# for Windows is the stock LLVM release and ships bin/clang.exe, and the three
# Unix ones ship bin/clang, so the name has to be built rather than written.
EXE = ".exe" if os.name == "nt" else ""


def host_platform() -> str:
    """Names the clang archive for the machine running this build."""
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux-" + platform.machine()
    if sys.platform == "win32":
        # x86_64 without asking, because it is the only Windows execution
        # platform the cc toolchain registers and the only one bazelw will
        # start on, so a machine that got this far is one.
        return "windows-x86_64"
    raise SystemExit(f"error: no clang archive for host '{sys.platform}'")


def clang_root() -> str:
    """Finds the unpacked clang archive, wherever this was run from."""
    name = ARCHIVE_PREFIX + host_platform()
    root = os.path.join(os.getcwd(), "external", name)
    if not os.path.isdir(root):
        # File paths in tests differ
        script_dir = os.path.dirname(os.path.abspath(__file__))
        repo_root = os.path.join(script_dir, *([os.pardir] * 4))
        root = os.path.join(repo_root, os.pardir, name)
    return root


def tokenize_param_file(text: str) -> list[str]:
    """Splits a response file the way the tool that would have read it does.

    This is the GNU tokenizer, which is what clang applies to @file and what
    Bazel writes for it. Whitespace separates arguments, a backslash outside
    quotes makes the next character literal, single quotes take their contents
    literally, and double quotes take theirs with backslash escapes. Adjacent
    runs join without a separator, so 'a'b is one argument and not two.

    Written out rather than handed to shlex because shlex is a POSIX shell
    lexer and this is not a shell. The differences are small and they are
    exactly the ones that would corrupt a Windows path.
    """
    args: list[str] = []
    current = ""
    started = False
    quote = ""
    i = 0
    while i < len(text):
        char = text[i]
        i += 1
        if not quote and char.isspace():
            if started:
                args.append(current)
                current = ""
                started = False
            continue
        started = True
        if char == "\\" and quote != "'" and i < len(text):
            current += text[i]
            i += 1
        elif not quote and char in "'\"":
            quote = char
        elif char == quote:
            quote = ""
        else:
            current += char
    if started:
        args.append(current)
    return args


def quote_for_param_file(arg: str) -> str:
    """Writes one argument in a form the tokenizer above reads back unchanged.

    Single quotes around everything, which is the one form with no escapes
    inside it, and the usual trick for an embedded single quote: close, escape
    it, reopen. Doing this to every argument rather than only the ones that need
    it keeps the rule simple enough to be obviously right.
    """
    return "'" + arg.replace("'", "'\\''") + "'"


def expand_param_files(argv: list[str]) -> tuple[list[str], str]:
    """Replaces @file with what is in it, and says which file that was.

    Everything below reads the link line argument by argument, to find our own
    --modular- options and to rewrite the ones lld-link will not take, so a
    command line that has been folded into a response file has to be unfolded
    first or none of it happens. The one that came in is named back to the
    caller so the rewritten line can be folded up again the same way.

    Only one, because Bazel writes one and does not nest them. An argument that
    starts with @ and does not name a file is left alone, since that is a real
    argument and not a response file.
    """
    expanded: list[str] = []
    param_file = ""
    for arg in argv:
        if arg.startswith("@") and os.path.isfile(arg[1:]):
            param_file = arg[1:]
            with open(param_file, encoding="utf-8") as handle:
                expanded.extend(tokenize_param_file(handle.read()))
        else:
            expanded.append(arg)
    return expanded, param_file


def split_args(argv: list[str]) -> Options:
    """Pulls our own arguments out of what is otherwise a clang command line."""
    ifs_input = ""
    ifs_output = ""
    dsym_path = ""
    binary_path = ""
    linker_args = []
    for arg in argv:
        if arg.startswith("--modular-ifs-input="):
            ifs_input = arg.split("=", 1)[1]
        elif arg.startswith("--modular-ifs-output="):
            ifs_output = arg.split("=", 1)[1]
        elif arg.startswith("--modular-dsym-path="):
            dsym_path = arg.split("=", 1)[1]
        elif arg.startswith("--modular-binary-path="):
            binary_path = arg.split("=", 1)[1]
        else:
            linker_args.append(arg)
    return Options(ifs_input, ifs_output, dsym_path, binary_path, linker_args)


def rewrite_for_windows(linker_args: list[str]) -> list[str]:
    """Turns a GNU style link line into one lld-link will accept.

    rules_cc puts -Xlinker -rpath -Xlinker $ORIGIN/<dir> on the link line for
    every directory a target's dynamic dependencies live in. That is right on
    Linux, and the same thing with @loader_path is right on macOS, and on
    Windows it is not so much wrong as meaningless. $ORIGIN is an ELF concept
    that the dynamic loader expands at load time, PE has no equivalent, and
    lld-link has no -rpath at all. It warns about the option it does not know,
    and then reads the path that followed it as an input file, so what comes out
    is

        lld-link: error: could not open '$ORIGIN/../_solib_win64/_USupport'

    which reads like a missing library rather than a flag nobody removed.

    Dropping them is the whole fix and not half of one. What an rpath is
    arranging, that a binary finds its shared libraries next to itself, is what
    the PE loader already does: its search order starts with the directory the
    executable was loaded from. There is nothing to translate the flag into.
    Windows still needs the DLLs to be in that directory rather than in a
    sibling _solib_ tree, but that is a runfiles layout question and not a link
    line one.

    This is done here, rather than by turning off the feature that generates
    them, because the feature cannot be turned off from outside rules_cc.
    rules_cc's own runtime_library_search_directories feature is not marked
    overridable, and it is pulled in wholesale by
    experimental_replace_legacy_action_config_features, which this toolchain
    enables. Overriding the legacy feature underneath it instead gets both into
    the toolchain under one name and fails analysis on every platform. The
    alternative was to copy rules_cc's twenty five entry feature list into our
    own BUILD file minus one line, and then keep that copy in step forever.

    The same loop translates whole archive inclusion, which is a rewrite rather
    than a removal. A cc_library marked alwayslink reaches the link line as

        -Wl,-whole-archive libfoo.a -Wl,-no-whole-archive

    where the two markers bracket a run of archives and mean "keep every object
    in these, referenced or not". lld-link does not know either marker, says so,
    and carries on, so every object nobody references is dropped. That is the
    quiet kind of wrong: the link succeeds, and what goes missing is static
    initializers and anything else registered by side effect at load time, which
    is found much later as a registry with holes in it rather than as a link
    error.

    The MSVC spelling is /WHOLEARCHIVE:<library>, which names one archive
    instead of opening a region, so each file between the markers gets its own.
    The archive still has to appear on the line as an input, because the flag
    says how to treat it and not that it is there, so the original argument is
    kept and the flag goes in front of it. Anything starting with a dash between
    the markers is left alone: Bazel puts only inputs there, and an option that
    turned up would be an option and not a name.

    Done here for the same reason as the rpath filtering above. rules_cc's own
    libraries_to_link feature already spells --start-lib the Windows way, so it
    has been through this once, but it hardcodes -Wl,-whole-archive everywhere
    except Apple, and it arrives through
    experimental_replace_legacy_action_config_features as one entry in a list
    this toolchain takes whole. Overriding it is not possible either, since it
    is itself the override of the legacy feature, and only a legacy feature can
    be overridden.
    """
    out: list[str] = []
    whole_archive = False
    i = 0
    while i < len(linker_args):
        arg = linker_args[i]
        # The generated form, four tokens: -Xlinker -rpath -Xlinker <path>.
        if arg == "-Xlinker" and linker_args[i + 1 : i + 2] == ["-rpath"]:
            i += 4
            continue
        # Not generated for this target today, but hand written -Wl,-rpath,DIR
        # is the spelling everywhere else in this tree, so it is cheaper to
        # catch it here than to find out later that one slipped through as a
        # filename.
        if arg == "-Wl,-rpath" or arg.startswith("-Wl,-rpath,"):
            i += 1
            continue
        if arg in ("-Wl,-whole-archive", "-Wl,--whole-archive"):
            whole_archive = True
            i += 1
            continue
        if arg in ("-Wl,-no-whole-archive", "-Wl,--no-whole-archive"):
            whole_archive = False
            i += 1
            continue
        if whole_archive and not arg.startswith("-"):
            out.append("-Wl,/WHOLEARCHIVE:" + arg)
        out.append(arg)
        i += 1
    return out


def build_interface_library(options: Options) -> int:
    """Writes the ELF stub shared object that stands in for a real one.

    Not Windows, which is finished by the time this runs. llvm-ifs reads ELF or
    a text stub and nothing else, so handing it a PE file does not fail, it
    segfaults: it decides the DOS header is a YAML stub and parses it. Reported
    as "Got empty plain scalar" followed by a stack dump, on a link that had
    already succeeded.
    """
    if not options.ifs_input or not options.ifs_output:
        print(
            "error: interface library input and output paths are required",
            file=sys.stderr,
        )
        return 1

    if sys.platform == "darwin":
        ifs_platform = "mac"
    elif platform.machine() == "x86_64":
        ifs_platform = "intel"
    else:
        ifs_platform = "graviton"

    ifs_root = os.path.join(
        os.getcwd(), "external", "+http_archive+llvm-ifs", "tools", ifs_platform
    )

    if os.environ.get("MACOS") == "true":
        command = [
            os.path.join(ifs_root, "llvm-readtapi.stripped"),
            "-arch",
            "arm64",
            "-extract",
            options.ifs_input,
            "-o",
            options.ifs_output,
        ]
    else:
        command = [
            os.path.join(ifs_root, "llvm-ifs.stripped"),
            options.ifs_input,
            "--output-elf=" + options.ifs_output,
        ]
    return subprocess.run(command).returncode


def main(argv: list[str]) -> int:
    """Rewrites the link line if it has to, links, and cleans up after."""
    argv, param_file = expand_param_files(argv)
    options = split_args(argv)
    windows = os.environ.get("WINDOWS") == "true"
    build_ifs = os.environ.get("BUILD_IFS") == "yes"
    linker_args = options.linker_args

    if windows:
        linker_args = rewrite_for_windows(linker_args)

        # Windows produces its interface library during the link rather than
        # after it, so the flag has to go on before clang runs. An import
        # library is what Windows has instead of the ELF stub shared object that
        # llvm-ifs writes, and lld-link is the thing that knows how to make one.
        # -Wl, because this is clang's GNU driver and a leading slash would
        # otherwise be read as a path.
        if build_ifs:
            if not options.ifs_output:
                print(
                    "error: interface library output path is required",
                    file=sys.stderr,
                )
                return 1
            linker_args.append("-Wl,/IMPLIB:" + options.ifs_output)

    root = clang_root()
    clang = os.path.join(root, "bin", "clang++" + EXE)

    # Fold it back up if it arrived folded. The link line is in a response file
    # because it does not fit on a command line, and it is no shorter now, so
    # passing it back argument by argument would fail to start the process on
    # the machine that needed the response file in the first place. Written
    # beside the one Bazel wrote, which is somewhere already known to be
    # writable, rather than in a temp directory that a strict action environment
    # may well not have told us about.
    rewritten = ""
    if param_file:
        rewritten = param_file + ".rewritten"
        with open(rewritten, "w", encoding="utf-8") as handle:
            handle.write(
                "".join(quote_for_param_file(a) + "\n" for a in linker_args)
            )
        linker_args = ["@" + rewritten]

    # Most links have nothing to do afterwards, so hand the process over rather
    # than hold a second one open for the length of the link. Not when a
    # response file was written, since somebody has to be here to delete it.
    nothing_after = not options.dsym_path and not (build_ifs and not windows)
    if nothing_after and not rewritten and os.name == "posix":
        os.execv(clang, [clang, *linker_args])

    try:
        status = subprocess.run([clang, *linker_args]).returncode
    finally:
        if rewritten:
            os.unlink(rewritten)
    if status != 0:
        return status

    if options.dsym_path:
        dsymutil = os.path.join(root, "bin", "dsymutil" + EXE)
        status = subprocess.run(
            [dsymutil, "-o", options.dsym_path, options.binary_path]
        ).returncode
        if status != 0:
            return status

    if not windows and build_ifs:
        return build_interface_library(options)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
