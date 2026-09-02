# Overview

## Scope

In scope is the Mojo compiler, the Mojo standard library, the runtime, and enough build and packaging work to produce a Mojo toolchain that runs on Windows and compiles Windows executables, for `x86_64` only.

Out of scope is MAX, anything GPU, and Windows on arm64. There is no Windows arm64 hardware available to test on and the ABI work would be a separate implementation. The only concession to it is that the ABI dispatch gets written to take an architecture and OS pair rather than being hardcoded to a binary choice, which costs nothing now.

Also out of scope, at least at first, is LLDB. Debug information will be DWARF in COFF sections, which LLDB understands and Visual Studio does not. Proper PDB emission is a later question.

## The two problems, which are not the same problem

**Targeting Windows.** Making the compiler produce a working Windows executable. This is compiler and standard library work, plus enough Bazel to describe a Windows target.

**Building on Windows.** Making the Bazel build run with Windows as the host. This is where the genuinely unpleasant work is. The three C++ toolchain driver scripts are bash. The `bazelw` bootstrapper reads `$OSTYPE` and calls `exit 1` on anything that is not Linux or macOS. `tools/bazel` generates a bazelrc on every invocation and has macOS only Xcode handling and Linux only `/dev/shm` handling. Then there is Bazel on Windows itself, with command line length limits, path length limits, symlink permissions, and the fact that upstream has both a `Mojo/` directory and links to `./mojo`, which collide on a case insensitive filesystem.

These are independent, so we do the first one first, cross compiling from Linux. That gets to a running `hello.exe` without touching any of the second problem.

## What already works

More than you would expect, which is the good news.

`Mojo/tools/mojo/Build/mojo-build.cpp` already emits `link.exe`, `.exe`, `.lib`, `/out:`, `/nologo`, `/SUBSYSTEM:CONSOLE`, `/machine:X64` and picks between `msvcrt.lib` and `msvcrtd.lib`. There is a comment in it saying "Mojo only supports X86_64 COFF right now", so somebody meant this.

`Support/include/Support/SymbolExport.h` already has the `__declspec(dllexport)` and `dllimport` handling.

`Mojo/tools/mojo-repl-entry-point/main.cpp` has a `WinMain`.

`Mojo/lib/MojoLLDB/Plugin.cpp` has a `_WIN32` name mangling workaround.

`bazel/internal/lit.common.cfg.py` already selects lit's internal shell on `win32`, which means a large share of test `RUN:` lines will work unmodified.

There is a comment in `Support/lib/Threading/HWInfo.cpp` that only makes sense if somebody once cross compiled this with MinGW.

The catch is that all of the compiler side of that is behind `#ifdef _WIN32`, which asks about the machine running the compiler rather than the machine the output is for. So it is unreachable when cross compiling and untested even natively. Rewiring host driven decisions to target driven ones is the bulk of the compiler work, and it is also the shape most likely to be accepted upstream, since it is a generalisation rather than a Windows special case.

## What is missing

**The Win64 calling convention.** Covered in [abi.md](abi.md). The only gap that fails silently and the only one with a hard release gate on it.

**A Windows target in the build graph.** No `@platforms//os:windows` anywhere. `Support/BUILD.bazel` has a `select()` with no default and no Windows arm, so analysis fails before any file is compiled. That will be the first error anyone sees. There are 276 OS keyed `select()` references across 91 files to work through.

**An MSVC sysroot.** Upstream mirrors Linux sysroot tarballs on S3, which is not available for Microsoft's CRT and SDK. The answer is `xwin`, which pulls them from Microsoft's own CDN under the Visual Studio license, run per machine as a repository rule and never mirrored.

**Things that do not compile under MSVC.** `AsyncRT/lib/Support/Semaphore.cpp` has a GCD path for Apple and a `<semaphore.h>` path for everything else, so it simply will not build. tcmalloc is included unconditionally and has no Windows support at all, so it is replaced with mimalloc rather than ported.

**Standard library POSIX assumptions.** Smaller than feared. Of 249 standard library files only 36 touch POSIX at all. `DLHandle` is the highest leverage single item, because fixing it unlocks around 150 CPython bindings in one change. `c_long` is an outright compile blocker under LLP64.

**The COFF JIT.** `ExecutionEngine.cpp` has a `FIXME` saying "On Windows, this complains about symbol not found" with the COFF branch commented out, and a note that the COFF JIT does not support in process symbols. Somebody hit this and stopped. This is deliberately kept off the critical path, because it blocks the REPL and `mojo run` but not `mojo build`.

**A shared library extension that is decided in two places.** `Support/BUILD.bazel` and `Mojo/lib/Support/Configuration.cpp` each decide it independently. The second one makes the compiler look for `libKGENCompilerRTShared.so` on Windows. Worth sweeping for a third before fixing either.

## What is not missing, and this is the big one

There is no exception handling work.

Mojo's `raises` does not use Itanium unwinding. It compiles to a `!kgen.variant<@Error, none>` return value and a `ByRefError` out parameter. It is a value, checked at the call site, not a stack unwind.

That matters more than anything else on this page. On a normal compiler port, getting Windows structured exception handling and funclets correct is a multi month piece of work that has to be right before anything else can be trusted. Here it is zero work, because the language never needed the mechanism in the first place.

This claim is worth re-checking first if the plan ever looks too good, since it is the single assumption that most changes the size of the project. It came from reading the actual lowering, not from documentation.

## How the work is grouped

Issues carry an `area/` label matching these.

`area/abi` is the calling convention and its conformance suite. `area/compiler` is everything else under `Mojo/lib` and `Mojo/tools`, mostly target driven rewiring. `area/runtime` is AsyncRT, the allocator, and the crash handler. `area/stdlib` is `Mojo/stdlib`. `area/build` is Bazel, the toolchain and the sysroot. `area/test` is the test suites and CI. `area/packaging` is releases and distribution. `area/upstream` is the pin, the overlay, and keeping up with upstream as it moves.
