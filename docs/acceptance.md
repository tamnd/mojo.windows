# Manual acceptance checklist

Things no automated suite here will catch, walked through by hand before a release that contains binaries.

CI does not run anything on Windows and is not going to. The Bazel suites do run on Windows, on one machine, driven from Linux, and between them they cover a great deal. What they do not cover is anything that needs a person looking at a screen, anything that depends on how a program was started rather than on what it does, and anything about the packaged archive as opposed to the build tree. That is what this list is.

Run it from a downloaded release archive and not from a build tree, on a machine that is not the one that built it if there is a choice. The build machine has the sysroot, the toolchain and every dependency already on it, and it is the least likely of any machine to notice that something is missing.

Record the result of each item in the release notes or in the milestone issue. An item that cannot be checked yet is a result, and writing down why is more useful than leaving the line blank.

## The list

1. **The REPL starts, evaluates and exits cleanly under cmd.exe, PowerShell and Windows Terminal.** Blocked until there is a Windows build of the compiler, which is M6. There is no `mojo.exe` to start.

2. **ANSI colour renders correctly, and degrades cleanly when piped to a file.** The mechanical half is checked: a program that prints `_use_color`, a line of non ASCII text and a green line reports `use_color: True` on a real console with `1b 5b 39 32 6d` before the green line, and reports `use_color: False` with not one escape byte when redirected to a file. The half that needs a person is whether the colours look right in cmd.exe, in PowerShell and in Windows Terminal, because a terminal can accept the escape and still render it as something nobody wants to read.

3. **Non ASCII source paths and non ASCII string literals round trip.** `Mojo/stdlib/test/os/test_non_ascii_path.mojo` covers the library side and runs in tier 0 on Windows: a directory and a file with accented characters, Japanese and an emoji in their names, written, read, listed and removed. The archive side is unpacking it under a path with those characters in it and running the program from there.

4. **A path containing spaces works throughout.** Unpack under `C:\Program Files` and run from it, both by absolute path and with the directory as the working directory. This is where a quoting mistake in a launcher or a runtime path lookup shows up.

5. **Ctrl-C interrupts a running program without orphaning child processes.** Needs a person at a real console. Console control events are delivered to a process group attached to a console, so this cannot be checked over a remote shell in any way that means anything.

6. **A crash produces a usable stack trace.** Build something that faults, run it, and see what comes out. Check more than one kind of fault. A null store and a stack overflow do not go through the same handler on Windows and are not supposed to look the same: the first prints an exception code and a symbolised frame list, the second prints one line naming the thread and exits with `0xC00000FD`. Checking only the easy one is how this item got recorded wrong the first time.

7. **A program built for Windows runs on a machine with no SDK and no redistributable installed.** The C runtime is linked statically, so the check is the import table: `hello.exe` should import `KERNEL32.dll` and the Mojo runtime and nothing else. Anything else in that list is a dependency somebody has to install first, which is the thing static linking was chosen to avoid.

8. **Antivirus does not quarantine the binaries.** Scan the unpacked archive and check that nothing was removed behind your back. [docs/downloading.md](downloading.md) has what to do when something is flagged.

## The v0.4.2 run

First end to end run, against the published `mojo-windows-runtime-0.4.2-x86_64.zip` downloaded from the releases page. One machine, Windows 11 26H1, build 10.0.28120.

1. **Not applicable.** No Windows build of the compiler, so there is no REPL to start.

2. **Half pass, half outstanding.** The escape bytes and the redirect behaviour were checked when #26 landed and both are correct. Nobody has looked at the colours in cmd.exe, PowerShell or Windows Terminal and said they read well, so that part is still open.

3. **Pass.** Unpacked under `C:\tmp\café-日本\mojo` and `bin\hello.exe` ran and printed, both by absolute path and with that directory as the working directory. The library side is green in tier 0.

4. **Pass.** Unpacked under `C:\Program Files\mojo windows test` and ran the same two ways.

5. **Not run.** Needs a person at a console and there is no long running program in the archive to interrupt anyway.

6. **Pass for an ordinary fault, fail for a stack overflow.** A null store built with `mojo build -g` prints an exception code and a symbolised frame list naming `__mojo_main_prototype` and the line in `_startup.mojo`, which is what this item asks for. Unbounded recursion built the same way prints nothing at all and exits with `0xC0000005`. An exception filter runs on the stack of the thread that faulted and a thread that has just overflowed its stack has none left, so the filter never starts. That is #239, and the fix is `SetThreadStackGuarantee`. Separately, unbounded recursion should raise `STATUS_STACK_OVERFLOW` and raised an access violation instead, which is what happens when a frame is large enough to step over the guard page without touching it, so it points at missing stack probes. That is #238.

7. **Pass.** `hello.exe` imports `KERNEL32.dll` and `KGENCompilerRTShared.dll` and nothing else. The machine it ran on is not SDK free, so the import table rather than the machine is what settles this, and the import table is the stronger evidence of the two.

8. **Pass.** Defender scanned the unpacked archive with real time protection on, engine 1.1.26080.3, signatures 1.459.49.0, and found nothing. One machine on one signature version, which is not a promise about anybody else's.

## The v0.5.1 run

Against `mojo-windows-runtime-0.5.1-x86_64.zip` as built by `scripts/package-windows.sh`, unpacked on the same machine as the previous run, Windows 11 26H1, build 10.0.28120. Still one machine, and still the machine that built it, which remains the weakest part of this checklist.

1. **Not applicable.** Same as before. There is no `mojo.exe`, so there is no REPL.

2. **Unchanged, half outstanding.** Nothing in the runtime touched colour handling since v0.4.2, so the mechanical half stands. Nobody has yet sat in front of cmd.exe, PowerShell and Windows Terminal and judged how the colours read.

3. **Pass.** Unpacked under `C:\tmp\rel051\café-日本`, which puts the archive's own top level directory below that. `bin\hello.exe` printed `Hello from Mojo` and `built for Windows: True` and exited 0, both by absolute path and with the unpacked directory as the working directory.

4. **Pass.** Unpacked under `C:\Program Files\mojo windows test 051` and ran the same two ways with the same output.

5. **Not run.** Same reason as before. It needs a person at a console and there is nothing long running in the archive to interrupt.

6. **Not re-run.** Nothing in the runtime, the startup code or the exception handler changed between v0.4.2 and v0.5.1, so the v0.4.2 result still describes what happens: an ordinary fault gives a usable trace and a stack overflow gives nothing. Those are #238 and #239 and both are still open.

7. **Pass.** `llvm-readobj --coff-imports` on `hello.exe` lists `KGENCompilerRTShared.dll` and `KERNEL32.dll` and nothing else.

8. **Pass.** Defender scanned the unpacked archive with real time protection on, engine 1.1.26080.3, signatures 1.459.56.0, and left every file in place.

## The v0.5.2 run

Against `mojo-windows-runtime-0.5.2-x86_64.zip` as built by `scripts/package-windows.sh`, unpacked on the same machine as the previous two runs, Windows 11 26H1, build 10.0.28120. Still one machine, and still the machine that built it.

Nothing in this release changes what is in the archive. Every change since v0.5.1 is build tooling for running the build on Windows rather than only targeting it, so the binaries here are the same programs from the same pin. The list was worked through anyway, because the point of a checklist is that it gets run and not that it gets reasoned about.

1. **Not applicable.** Still no `mojo.exe`, so still no REPL. #251 got the cc toolchain resolving on a Windows host, which is a step toward one, but a resolving toolchain is not a compiler.

2. **Unchanged, half outstanding.** Nothing has touched colour handling since v0.4.2. The mechanical half stands and nobody has yet sat in front of cmd.exe, PowerShell and Windows Terminal and judged how the colours read.

3. **Pass.** Unpacked under `C:\tmp\rel052\café-日本`. `bin\hello.exe` printed `Hello from Mojo` and `built for Windows: True` and exited 0, both by absolute path and with the unpacked directory as the working directory.

4. **Pass.** Unpacked under `C:\Program Files\mojo windows test 052` and ran the same two ways with the same output.

5. **Not run.** Needs a person at a console, and there is still nothing long running in the archive to interrupt.

6. **Not re-run.** Nothing in the runtime, the startup code or the exception handler changed since v0.4.2, so that result still describes what happens: an ordinary fault gives a usable trace and a stack overflow gives nothing. #238 and #239 are both still open.

7. **Pass.** `llvm-readobj --coff-imports` on `hello.exe` lists `KGENCompilerRTShared.dll` and `KERNEL32.dll` and nothing else.

8. **Pass.** Defender scanned the unpacked archive with real time protection on, engine 1.1.26080.3, signatures 1.459.56.0, and left all twelve files in place.

## The v0.5.5 run

Against `mojo-windows-runtime-0.5.5-x86_64.zip` as built by `scripts/package-windows.sh`, unpacked on the same machine as every run before it, Windows 11 26H1, build 10.0.28120. Still the machine that built it, which is still the weakest part of this checklist.

The first full run since v0.5.2, and the first release since v0.5.0 where the binaries in the archive are a different program rather than the same ones repackaged. #273 changed the runtime, and item 6 is the item that covers what it changed.

1. **Not applicable.** Still no `mojo.exe`, so still no REPL to start.

2. **Unchanged, half outstanding.** Nothing has touched colour handling since v0.4.2, so the mechanical half stands. Nobody has yet sat in front of cmd.exe, PowerShell and Windows Terminal and judged how the colours read.

3. **Pass.** Unpacked under `C:\tmp\rel055\café-日本\unpacked`. `bin\hello.exe` printed `Hello from Mojo` and `built for Windows: True` and exited 0, both by absolute path and with the unpacked directory as the working directory.

4. **Pass.** Unpacked under `C:\Program Files\mojo windows test 055` and ran the same two ways with the same output.

5. **Not run.** Needs a person at a console, and there is still nothing long running in the archive to interrupt.

6. **Pass, both kinds.** This is the item that has been a partial failure since v0.4.2 and it passes now. A program that raises an access violation prints `Exception Code: 0xC0000005` and five symbolised frames and exits with that code. A program that recurses until the stack runs out prints `Stack overflow in thread 10040. The usual cause is recursion with no base case.` and exits with `0xC00000FD`, which is both halves of what #239 asked for and also settles #238, since the code that arrives is a stack overflow and not an access violation.

    Writing a program that actually overflows is harder than it reads, and it is worth writing down because it cost most of the time this item took. Recursion whose result feeds an addition is not safe to assume will use stack: `return work + recurse(n + 1)` is an associative accumulation and LLVM turns it into a loop, alloca and all, so the program runs forever at a fixed stack depth and prints nothing. That looks exactly like the failure this item is meant to catch. What works is keeping the frame live across the recursive call, by reading a `stack_allocation` with a volatile load after the call comes back rather than only before it. Then there is nothing to fold and every frame stays on the stack.

7. **Pass.** `llvm-objdump -p` on `hello.exe` lists `KGENCompilerRTShared.dll` and `KERNEL32.dll` and nothing else. Earlier runs used `llvm-readobj --coff-imports` for this, and the toolchain archive the build fetches does not ship `llvm-readobj`, so `llvm-objdump -p` is the one to reach for.

8. **Pass.** Defender scanned both unpacked copies with real time protection on, engine 1.1.26080.3, signatures 1.459.64.0, and left all twelve files in each of them in place.

## The v0.5.6 run

Against `mojo-windows-runtime-0.5.6-x86_64.zip` as built by `scripts/package-windows.sh`, unpacked on the same machine as every run before it, Windows 11 26H1, build 10.0.28120. Still the machine that built it, which is still the weakest part of this checklist.

#197 changed the startup code, so item 6 is a real run again rather than a carried over result. It is the item that covers what happens when a program goes wrong, and the startup wrapper is where the handlers that decide that get installed.

1. **Not applicable.** Still no `mojo.exe`, so still no REPL to start.

2. **Unchanged, half outstanding.** Nothing has touched colour handling since v0.4.2, so the mechanical half stands. Nobody has yet sat in front of cmd.exe, PowerShell and Windows Terminal and judged how the colours read.

3. **Pass.** Unpacked under `C:\tmp\rel056\café-日本\unpacked`. `bin\hello.exe` printed `Hello from Mojo` and `built for Windows: True` and exited 0, both by absolute path and with the unpacked directory as the working directory.

4. **Pass.** Unpacked under `C:\Program Files\mojo windows test 056` and ran the same two ways with the same output.

5. **Not run.** Needs a person at a console, and there is still nothing long running in the archive to interrupt.

6. **Pass, both kinds.** A program that stores through a pointer to nothing prints `Exception Code: 0xC0000005` and a frame list and exits with that code. A program that recurses until the stack runs out prints `Stack overflow in thread 3692. The usual cause is recursion with no base case.` and exits with `0xC00000FD`. Both are what v0.5.5 recorded, so the invalid parameter handler #197 installs at startup does not get in the way of either.

    Two things about writing the second program are worth adding to what v0.5.5 already wrote down, because both cost time again. Keeping a `stack_allocation` live across the recursive call with a volatile load after it comes back is necessary and it is not sufficient: a function that calls itself and then adds something to the result is still an associative accumulation, and it still came back as a loop that ran at a fixed stack depth for ten minutes without faulting. What works is mutual recursion, two functions calling each other, which nothing rewrites into a loop. The frames in the first program are addresses and module offsets rather than names, because the program was built for this run and its debug information was not put next to it in the staging directory. The packaged `hello.exe` has the same shape and its symbols live in the separate `-pdb.zip`.

7. **Pass.** `llvm-objdump -p` on `hello.exe` lists `KGENCompilerRTShared.dll` and `KERNEL32.dll` and nothing else.

8. **Pass.** Defender scanned both unpacked copies with real time protection on, engine 1.1.26080.3, signatures 1.459.74.0, and left all twelve files in each of them in place.
