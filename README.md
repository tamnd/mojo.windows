# mojo.windows

Native Windows support for the Mojo compiler and standard library, maintained as a pinned commit plus a file overlay on top of upstream `modular/modular`.

> **Not affiliated with Modular or Qualcomm.** This is an unofficial community project. "Mojo" is a trademark of Modular Inc. and is used here only to say what this project changes. Do not file Windows bugs from this project on the upstream tracker.

## Status

Early, but past the interesting part. A Mojo program cross compiled from Linux produces a `hello.exe` that runs on Windows 11 and prints, and the standard library tiers behind it are green: tier 0 is 232 of 238 on Windows and tier 1 is 74 of 77, with the Win64 ABI conformance suite at thirteen of thirteen. `//Mojo/examples/windows-hello:hello` is that program and [docs/building.md](docs/building.md) has the command. From v0.4.2 it is also on the [releases page](https://github.com/tamnd/mojo.windows/releases) as a zip with the runtime, the import libraries and checksums, so you can download it and run it without building anything. What is not done is building on Windows rather than for it, so there is no `mojo.exe` in that zip and nothing to compile with on the machine yet.

Track progress on the [milestones](https://github.com/tamnd/mojo.windows/milestones).

## Supported Windows versions

x64 only, Windows 10 version 1809 and later, which is build 17763 and is also Windows Server 2019.

That is a decision rather than a measurement, so here is what it rests on and where it is soft. Nothing in the binaries needs anything close to it: every symbol `hello.exe` and `KGENCompilerRTShared.dll` import from the system was checked against the version it first appeared in, and the newest are `GetLogicalProcessorInformationEx` and the processor group calls in the runtime, which are Windows 7. The PE header asks for 6.0, meaning Vista. So the floor is set by what we are prepared to stand behind, not by what the code can execute on.

What we are prepared to stand behind is limited by what actually gets run, and that is one machine on Windows 11. Nothing older has been tested. 1809 is the number because it is the oldest servicing baseline worth naming, because the UCRT is in the box from Windows 10 onwards, and because Server 2019 is the same build so the server question answers itself. Something older may well work. It is not a promise.

Two things degrade rather than fail below that line. Console colour needs virtual terminal processing, which is Windows 10 1511 and later, and the UTF-8 process code page in the application manifest needs Windows 10 1903, so Server 2019 gets everything except that one.

No Visual C++ redistributable is needed. Both link paths use the static C runtime, so `hello.exe` imports `KERNEL32.dll` and `KGENCompilerRTShared.dll` and nothing else. The DLL runtime would have meant `VCRUNTIME140.dll` on the target machine, which is on most of them and guaranteed on none, and that is not a thing to make somebody install before a downloaded binary will start.

## Windows will warn about the download

The binaries are unsigned and published by somebody Windows has never heard of, so double clicking `hello.exe` in Explorer raises the SmartScreen dialog, "Windows protected your PC", with the Run anyway button hidden behind More info. That is expected, it is not a symptom of a broken build, and it is not something a rebuild fixes. Check the SHA-256 against `SHA256SUMS-windows` in the release, which is the thing that actually tells you what you have, and then run it.

One wrinkle worth knowing: whether you see that dialog at all depends on how you unpacked the zip. Explorer copies the mark of the web onto every file it extracts and `Expand-Archive` in PowerShell does not, so the same download behaves differently for two people. [docs/downloading.md](docs/downloading.md) has the detail, along with what Defender made of the archive and why nothing here is signed.

## Why this exists

Mojo was open sourced in August 2026 under Apache 2.0 with LLVM Exceptions, which makes the compiler modifiable for the first time. Modular has announced a partnership with Microsoft for Windows support but has not published a date or a design. So the only way to get Mojo running on Windows right now is to change it yourself.

This project is meant to become unnecessary. When Modular and Microsoft ship official Windows support, the right ending is to archive this and point people at theirs. Nothing here is submitted upstream, and #35 says why.

## What we found

Five things came out of the source audit that shape the whole plan. The detail is in [docs/](docs/).

**Windows support is already half there, but wired to the wrong thing.** `Mojo/tools/mojo/Build/mojo-build.cpp` already knows how to emit `link.exe` arguments, `.exe` and `.lib` extensions, `/SUBSYSTEM:CONSOLE` and `/machine:X64`. All of it sits behind `#ifdef _WIN32`, which tests the machine running the compiler rather than the machine the output is for. So it is unreachable when cross compiling and untested even natively. Most of the compiler work is rewiring this from host driven to target driven, not writing it from scratch.

**There is no exception handling work at all.** This is the single biggest reason the project is tractable. Mojo's `raises` is value based, using a `!kgen.variant<@Error, none>` return and a `ByRefError` out parameter, not Itanium unwinding. On a normal compiler port, getting SEH and funclets right is a multi month slog. Here it is zero.

**The ABI gap fails silently, and that is dangerous.** `Mojo/lib/KGENToLLVM/CABILowering.cpp` picks a calling convention from the architecture alone. For `x86_64` it always returns `SystemVABIInfo`, with no check on the OS. Point that at Windows and the code compiles, links, runs, and reads arguments out of the wrong registers. Every other gap in this project fails loudly with a build error. This one produces garbage values and stack corruption a long way from the cause, and plenty of calls behave identically under both ABIs so a green test run proves nothing. That is why there is a mandatory differential conformance suite that checks our lowering against what MSVC actually does, and why no binary ships until it passes.

**Targeting Windows and building on Windows are separate problems.** All the really unpleasant blockers, the bash toolchain driver scripts, the `bazelw` wrapper that exits on anything other than Linux or macOS, and general Bazel on Windows friction, live in the second problem. So we cross compile from Linux first and worry about a native Windows build later.

**The build system will fail before it compiles a single file.** `Support/BUILD.bazel` has a `select()` on the OS with no default branch and no Windows branch, so a Windows targeted build dies during analysis. That will be the very first error anyone sees.

## How the upstream pin works

There is no GitHub fork. A fork of a repository this size would drag in a million lines we do not touch, inherit six upstream workflows we do not want firing, and make it hard to tell our changes apart from theirs.

Instead this repository holds three things: a pinned upstream commit in [`upstream.lock`](upstream.lock), the files we change in [`overlay/`](overlay/), and the scripts that put them together. Only files this project has actually changed are committed here, and the overlay is currently about 130 kilobytes.

```sh
./scripts/sync.sh
```

That clones upstream at the pinned commit into `.upstream/modular`, which is gitignored, and lays the overlay on top. You get a normal git working tree you can build and hack on.

To make a change, edit the file in `.upstream/modular` like ordinary source, then run:

```sh
./scripts/refresh.sh
```

That copies everything differing from the pin back into `overlay/`. You do not have to say which files you touched, so taking over a file nobody has changed before is just editing it.

To move to a newer upstream release:

```sh
./scripts/bump-upstream.sh
```

That does a three way merge of every overlay file onto the newer upstream, using upstream's version at the old pin as the base. If everything merges it updates the lock and the overlay. If something conflicts it changes nothing and leaves the conflict markers in the file for you. A scheduled workflow runs this every week and opens a pull request when a bump is clean, or files an issue when it is not, so drift shows up as a notification rather than as a surprise six months later.

The full explanation, including why this shape over a fork, a submodule or a subtree, is in [docs/upstream.md](docs/upstream.md).

## Documentation

| Document | What is in it |
| --- | --- |
| [docs/overview.md](docs/overview.md) | Scope, what is missing, how the work is grouped |
| [docs/abi.md](docs/abi.md) | The Win64 calling convention gap and the conformance suite |
| [docs/upstream.md](docs/upstream.md) | Pinning, the overlay, rebasing onto a newer upstream |
| [docs/building.md](docs/building.md) | Cross compiling from Linux, toolchain and sysroot |
| [docs/roadmap.md](docs/roadmap.md) | Milestones M0 to M8 and rough effort |
| [docs/releasing.md](docs/releasing.md) | What a version means, what is in a release, how one is cut |
| [docs/downloading.md](docs/downloading.md) | Running a release, checksums, SmartScreen and antivirus |

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. The short version is that every change has to keep the Linux and macOS test suites green. Linux is the baseline we develop against and the only thing that tells us a Windows change broke something general rather than something Windows specific, so a change that regresses it is a change we cannot evaluate.

Good places to start are the issues labelled [good first issue](https://github.com/tamnd/mojo.windows/labels/good%20first%20issue).

## License

Apache 2.0 with LLVM Exceptions, matching upstream. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
