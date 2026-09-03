//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#include "Support/Process.h"
#include "Support/SymbolExport.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/FileUtilities.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Process.h"
#include "llvm/Support/Program.h"
#include <cctype>
#include <optional>
#include <string>

#ifdef _WIN32
#include <windows.h>
#endif

using namespace M;

using llvm::sys::findProgramByName;
using llvm::sys::fs::is_regular_file;

// Works across ubuntu 20.04, 22.04, macos, pyenv, conda, venv, virtual
//
// The Windows branch is not the same shape as the rest and does not need to be.
// LIBPL and LIBDIR are both unset there, so `Path(None)` is a TypeError and the
// loop below would have found nothing however long the list of directories got,
// and the spelling is different too: the library is `python314.dll` rather than
// `libpython3.14.dll`. Rather than reconstruct a name and then go looking for
// it, the branch asks the loader where the library it is already running out of
// came from. `sys.dllhandle` is the module handle of that library, and it is
// exactly the file that wants loading. That answer is right for an installer
// build, a store build, a venv and a conda environment without any of them
// being thought about, and it is right for a free threaded build, whose library
// has a `t` on the end of its name that a reconstruction would have to know
// about.
const char *FIND_LIBPYTHON = R"PROG(
import os
import sys
from pathlib import Path
from sysconfig import get_config_var
if os.name == "nt":
    import ctypes
    name = ctypes.create_unicode_buffer(32768)
    ctypes.windll.kernel32.GetModuleFileNameW(
        ctypes.c_void_p(sys.dllhandle), name, len(name)
    )
    if not name.value:
        exit(1)
    print(name.value)
    exit(0)
ext = "dylib" if sys.platform == "darwin" else "so"
pyver = get_config_var("py_version_short")
abiflags = get_config_var("ABIFLAGS") or ""
binary = f"libpython{pyver}{abiflags}.{ext}"
for libpython in [Path(get_config_var(p)) / binary for p in ["LIBPL", "LIBDIR"]]:
    if libpython.exists():
        print(libpython.resolve())
        exit(0)
exit(1)
)PROG";

//===----------------------------------------------------------------------===//
// KGEN_CompilerRT_Python_SetPythonPath
//===----------------------------------------------------------------------===//

// TODO: add a subprocess module to Mojo so this can all be done natively
// Returns path to a libpython of the same version as `pythonBin`
static std::optional<std::string> findLibPython(const std::string &pythonBin) {
  // The script goes to the interpreter as one argument, and no shell is
  // involved. This used to build a command string and hand it to popen, which
  // is two problems on Windows rather than one. The small problem is that popen
  // is spelled _popen there. The large one is that popen means a shell, and the
  // shell it means is cmd.exe, which does not agree with sh about any part of
  // what is written above: it has no single quote, so the quotes around the
  // script would have arrived at Python as literal characters, and it treats
  // the newlines inside the script as the end of the command. The result would
  // not have been a diagnostic, it would have been an empty answer that the
  // caller reads as "look for CPython in the current process".
  //
  // Passing argv directly takes the shell out of the question everywhere, so
  // there is no _WIN32 branch here and no quoting to get right on either side.
  llvm::SmallString<128> outputPath;
  if (llvm::sys::fs::createTemporaryFile("mojo-libpython", "txt", outputPath))
    return std::nullopt;
  llvm::FileRemover removeOutput(outputPath);

  // stdin and stderr stay inherited, which is what popen did. Only stdout is
  // captured, and it goes to a file because there is no portable way to read a
  // pipe and wait for the child without risking a deadlock on a full pipe.
  std::optional<llvm::StringRef> redirects[] = {
      std::nullopt, llvm::StringRef(outputPath), std::nullopt};
  llvm::StringRef args[] = {pythonBin, "-c", FIND_LIBPYTHON};

  // The exit status is deliberately ignored, because it was ignored before and
  // the caller depends on that. The script exits 1 when it finds nothing, and
  // an empty result is not the same as no result: it means dlopen(nullptr), and
  // that is the working answer on a Linux where python is a PIE executable with
  // CPython linked into it. See `isUsableLibPython` for why Windows is the
  // exception.
  llvm::sys::ExecuteAndWait(pythonBin, args, /*Env=*/std::nullopt, redirects);

  auto buffer = llvm::MemoryBuffer::getFile(outputPath);
  if (!buffer)
    return std::nullopt;

  std::string result = (*buffer)->getBuffer().str();
  std::erase_if(result, ::isspace);
  return result;
}

// The names to try on `PATH`, in the order to try them, which is not the same
// order everywhere. On a Unix `python3` is the one that is certain to be a
// Python 3 and `python` may be a Python 2 or may be missing, so `python3` goes
// first. On Windows that convention never took: the installer lays down
// `python.exe` and no `python3.exe` at all, and the only `python3.exe` on a
// stock Windows 11 is the Microsoft Store stub, a program that prints an
// advertisement for the store and exits without running anything. Looking for
// `python3` first there finds the stub every time and never gets as far as the
// real interpreter sitting beside it on `PATH`.
//
// The launcher, `py.exe`, is deliberately not in the list. It would find a
// Python on a machine where neither name is on `PATH`, but it is not itself an
// interpreter, and `PYTHONEXECUTABLE` is supposed to name one.
static llvm::ArrayRef<llvm::StringRef> pythonProgramNames() {
#ifdef _WIN32
  static const llvm::StringRef names[] = {"python", "python3"};
#else
  static const llvm::StringRef names[] = {"python3", "python"};
#endif
  return names;
}

// Whether an answer from `findLibPython` is worth using.
//
// Everywhere but Windows an empty answer counts, because it means look for
// CPython in the current process, which is the working answer on a Linux where
// `python` is a PIE executable with the interpreter linked into it. Windows
// never does that: the interpreter is always in a `pythonXY.dll` beside
// `python.exe` and never inside it, and the loader has no handle that searches
// every module in the process anyway. So an empty answer there is a candidate
// that did not work rather than one that worked differently, and the caller
// should go on to the next name. That is also how the Store stub gets
// recognised, without this file having to know what its path looks like: it is
// not a Python, so it produces nothing, so it is skipped.
static bool isUsableLibPython(const std::optional<std::string> &libpython) {
  if (!libpython)
    return false;
#ifdef _WIN32
  return !libpython->empty();
#else
  return true;
#endif
}

COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT const char *
KGEN_CompilerRT_Python_SetPythonPath() {
  auto pythonBin = llvm::sys::Process::GetEnv("MOJO_PYTHON").value_or("");
  if (!pythonBin.empty() && !is_regular_file(pythonBin))
    return "`MOJO_PYTHON` is not set to a file path.";

  // If `MOJO_PYTHON_LIBRARY` is set, the caller has settled the question and
  // the interpreter is only wanted for `PYTHONEXECUTABLE`.
  auto libpython = llvm::sys::Process::GetEnv("MOJO_PYTHON_LIBRARY");

  if (!pythonBin.empty()) {
    if (!libpython)
      libpython = findLibPython(pythonBin);
  } else {
    // Take the first name on `PATH` that leads to a library, rather than the
    // first name on `PATH`. The two used to be the same thing, because a
    // program called python that is not a Python is not something a Unix has,
    // and Windows has one installed by default.
    for (llvm::StringRef name : pythonProgramNames()) {
      auto found = findProgramByName(name);
      if (!found)
        continue;
      pythonBin = *found;
      if (libpython)
        break;
      auto candidate = findLibPython(pythonBin);
      if (isUsableLibPython(candidate)) {
        libpython = candidate;
        break;
      }
    }
  }

  // `PYTHONEXECUTABLE` enables multiprocessing, and adding virtual environment
  // site-modules. Not strictly required in an environment with no executable.
  if (!pythonBin.empty())
    if (failed(setProcessEnv("PYTHONEXECUTABLE", pythonBin)))
      return "cannot set `PYTHONEXECUTABLE` to";

  // Intentionally setting MOJO_PYTHON_LIBRARY to "" should result in
  // `dlopen(nullptr, ..)`, to look for CPython symbols in the current process.
  // That behavior is important on platforms (Linux), where the Python `python`
  // executable statically links the CPython implementation but can't be
  // `dlopen()`'d directly because it is a PIE executable. On Windows there is
  // nothing for it to mean, so an empty setting is an error there rather than
  // an instruction.
  if (!isUsableLibPython(libpython) ||
      (*libpython != "" && !is_regular_file(*libpython)))
    return "found no suitable Python library to link to";

  if (failed(setProcessEnv("MOJO_PYTHON_LIBRARY", *libpython)))
    return "cannot set `MOJO_PYTHON_LIBRARY`";

  return "";
}
