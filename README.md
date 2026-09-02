# mojo.windows

Native Windows support for the Mojo compiler and standard library, maintained as a pinned patch series on top of upstream `modular/modular`.

> **Not affiliated with Modular or Qualcomm.** This is an unofficial community project. "Mojo" is a trademark of Modular Inc. and is used here only to say what this project patches. Do not file Windows bugs from this project on the upstream tracker.

## Status

Early. Nothing builds for Windows yet. What exists today is the design work, the upstream pinning machinery, and the issue backlog. The first milestone that produces a runnable artifact is M3.

Track progress on the [milestones](https://github.com/tamnd/mojo.windows/milestones).

## Why this exists

Mojo was open sourced in August 2026 under Apache 2.0 with LLVM Exceptions, which makes the compiler modifiable for the first time. Modular has announced a partnership with Microsoft for Windows support but has not published a date or a design, and is not currently taking compiler pull requests from outside. So the only way to get Mojo running on Windows right now is to patch it yourself.

This project is meant to become unnecessary. Every patch is written in a shape that could be handed to upstream as is, so that when Modular opens the compiler up, the work converts into contributions instead of being thrown away.

## What we found

Five things came out of the source audit that shape the whole plan. The detail is in [docs/](docs/).

**Windows support is already half there, but wired to the wrong thing.** `Mojo/tools/mojo/Build/mojo-build.cpp` already knows how to emit `link.exe` arguments, `.exe` and `.lib` extensions, `/SUBSYSTEM:CONSOLE` and `/machine:X64`. All of it sits behind `#ifdef _WIN32`, which tests the machine running the compiler rather than the machine the output is for. So it is unreachable when cross compiling and untested even natively. Most of the compiler work is rewiring this from host driven to target driven, not writing it from scratch.

**There is no exception handling work at all.** This is the single biggest reason the project is tractable. Mojo's `raises` is value based, using a `!kgen.variant<@Error, none>` return and a `ByRefError` out parameter, not Itanium unwinding. On a normal compiler port, getting SEH and funclets right is a multi month slog. Here it is zero.

**The ABI gap fails silently, and that is dangerous.** `Mojo/lib/KGENToLLVM/CABILowering.cpp` picks a calling convention from the architecture alone. For `x86_64` it always returns `SystemVABIInfo`, with no check on the OS. Point that at Windows and the code compiles, links, runs, and reads arguments out of the wrong registers. Every other gap in this project fails loudly with a build error. This one produces garbage values and stack corruption a long way from the cause, and plenty of calls behave identically under both ABIs so a green test run proves nothing. That is why there is a mandatory differential conformance suite that checks our lowering against what MSVC actually does, and why no binary ships until it passes.

**Targeting Windows and building on Windows are separate problems.** All the really unpleasant blockers, the bash toolchain driver scripts, the `bazelw` wrapper that exits on anything other than Linux or macOS, and general Bazel on Windows friction, live in the second problem. So we cross compile from Linux first and worry about a native Windows build later.

**The build system will fail before it compiles a single file.** `Support/BUILD.bazel` has a `select()` on the OS with no default branch and no Windows branch, so a Windows targeted build dies during analysis. That will be the very first error anyone sees.

## How the upstream pin works

There is no GitHub fork. A fork of a repository this size would drag in a million lines we do not touch, inherit six upstream workflows we do not want firing, and make it hard to tell our changes apart from theirs.

Instead this repository holds three things: a pinned upstream commit in [`upstream.lock`](upstream.lock), a series of `git format-patch` files in [`patches/`](patches/), and the scripts that put them together. Upstream source is never committed here.

```sh
./scripts/sync.sh
```

That clones upstream at the pinned commit into `.upstream/modular`, which is gitignored, and applies the series on top. You get a normal git working tree you can build and hack on.

To make a change, commit it inside `.upstream/modular` and run:

```sh
./scripts/refresh.sh
```

That exports your commits back into `patches/`. One logical change per commit, with a real subject line, because the subject line is the filename and it is the first thing an upstream reviewer would read.

To move to a newer upstream release:

```sh
./scripts/bump-upstream.sh
```

That replays the series onto the newest upstream tag. If everything applies it updates the lock and the patches. If something conflicts it changes nothing and tells you which patch broke. A scheduled workflow runs this every week and opens a pull request when a bump is clean, or files an issue when it is not, so drift shows up as a notification rather than as a surprise six months later.

The full explanation, including why this shape over a fork, a submodule or a subtree, is in [docs/upstream.md](docs/upstream.md).

## Documentation

| Document | What is in it |
| --- | --- |
| [docs/overview.md](docs/overview.md) | Scope, what is missing, how the work is grouped |
| [docs/abi.md](docs/abi.md) | The Win64 calling convention gap and the conformance suite |
| [docs/upstream.md](docs/upstream.md) | Pinning, the patch series, rebasing, upstreaming |
| [docs/building.md](docs/building.md) | Cross compiling from Linux, toolchain and sysroot |
| [docs/roadmap.md](docs/roadmap.md) | Milestones M0 to M8 and rough effort |

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. The short version is that every patch has to keep the Linux and macOS test suites green, because a patch that regresses the platforms Modular actually ships is a patch that can never go upstream.

Good places to start are the issues labelled [good first issue](https://github.com/tamnd/mojo.windows/labels/good%20first%20issue).

## License

Apache 2.0 with LLVM Exceptions, matching upstream. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
