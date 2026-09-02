# Building

Nothing here produces a Windows binary yet. This document describes the approach and what it will take, so that the issues make sense. Milestone M3 is the first point at which any of it works.

## Get a working tree

```sh
./scripts/sync.sh
```

Upstream lands in `.upstream/modular` at the pinned commit with our series applied. Build from there. The first clone is large and slow, everything after that is not.

Always use `./bazelw` from inside that checkout rather than a system Bazel or a release tarball. The `tools/bazel` wrapper generates `build/wrapper.bazelrc` on every invocation, and `.bazelrc` imports it, so a tree where that wrapper has never run fails with a confusing message about a nonexistent path in an import declaration.

You also have to pass one of `--config=build-mojo` or `--config=prebuilt-mojo`. The wrapper enforces it. For this project it is always `build-mojo`, because `prebuilt-mojo` downloads a nightly wheel from Modular and there will never be a Windows one there.

## Say who built it

Every binary produced here has to identify itself as not being a Modular build. The first patch in the series adds three Bazel settings for that, `//:downstream_id`, `//:downstream_build` and `//:downstream_upstream_commit`, all empty by default. Empty means the binary claims to be an ordinary Modular build, which for anything built here would be untrue, so pass them on every build:

```sh
cd .upstream/modular
./bazelw build --config=build-mojo $(../../scripts/downstream-flags.sh) //Mojo/tools/mojo
```

`scripts/downstream-flags.sh` works the values out rather than hardcoding them. The build revision is this repository's `HEAD`, suffixed with `-dirty` when the tree has uncommitted changes, and the upstream commit comes from `upstream.lock`. Nothing in it goes stale when the pin moves.

The result is that `mojo --version` names the project and the revision on its first line, `mojo --version --verbose` adds the upstream commit, and a crash points the reporter here instead of at Modular's tracker.

## Cross compiling, which is the plan

We build on Linux and target Windows. Every Bazel action still runs on Linux, which means the bash toolchain drivers keep working and the `bazelw` bootstrapper never has to deal with Windows. That avoids a whole category of problems until we choose to take them on.

Pieces needed, roughly in the order they bite:

**A Windows platform.** A `windows_x86_64` platform and matching `config_setting`, plus a fourth entry in the toolchain registration, registered with a Linux execution constraint and a Windows target constraint. That shape is what keeps the bash drivers viable.

**A sysroot.** Microsoft's CRT and Windows SDK headers and import libraries. Unlike the Linux sysroots, these cannot be mirrored, so we use `xwin`, which fetches them from Microsoft's CDN under the Visual Studio license. It goes in as a repository rule. There is precedent in the tree for a non hermetic sysroot, since the macOS one already shells out to `xcrun`.

Each machine that runs `xwin` accepts the license itself. The output must not be mirrored into a public artifact store.

**Toolchain flags.** Add `x86_64-pc-windows-msvc` to the target triples. The existing GNU and Mach-O linker flags do not apply to COFF and need a parallel set. `-fPIC` is meaningless on PE, `-fvisibility=hidden` is a no-op since PE is hidden by default, which is why `SymbolExport.h` exists at all. Artifact name patterns for `.dll`, `.lib`, `.exp` and `.pdb` need adding.

Use `clang` in GNU driver mode with `--target=x86_64-pc-windows-msvc`, not `clang-cl`. Every existing flag in the toolchain is GNU style and switching driver modes would mean rewriting all of them. Clang's GNU driver targets the MSVC ABI perfectly well. Only the linker needs MSVC style arguments and that is `lld-link`'s job. It also sidesteps a known Bazel bug where `clang-cl -v` output is misparsed and Bazel looks in the wrong `lib/clang` directory.

The good news here is that this toolchain is built on the modern `rules_cc` Starlark API rather than legacy `unix_cc_toolchain_config`, and that API handles MSVC through the same primitives. The scaffolding is genuinely OS agnostic. Only the flag values are Unix shaped.

**Dependencies that have to be gated out rather than ported.** tcmalloc depends on glibc restartable sequences and Linux NUMA topology and has no Windows port, so it is replaced with mimalloc. libfabric, nixl, uccl, ucx, rocshmem and nvshmem are Linux and GPU cluster specific and are excluded. Crashpad is portable and upstream supports Windows properly, it just is not wired up here. grpc, protobuf, abseil, opentelemetry, asio, fmt, zlib-ng, zstd and the rest are fine as they are.

## Linking

`lld-link`, bundled. It is what the Rust and clang-cl ecosystems use, it is mature, and bundling it means a user does not need a Visual Studio install to link, which is a real advantage over depending on `link.exe`. Keep `link.exe` selectable behind a flag in case a gap turns up.

Two things to check when wiring this up. `-Wl,--gc-sections` currently sits outside the `_WIN32` split in `mojo-build.cpp`, so on the Windows path it gets handed to a linker that does not understand it. The COFF equivalent is `/OPT:REF`. And the shared library path has no `/WHOLEARCHIVE:`, whose absence silently drops symbols out of static archives. Both are one line fixes once found, and both are good evidence that this code has never actually been run.

## Testing a cross build

Bazel cannot natively run a Windows test from a Linux execution host. Start with `--run_under` and a small script that copies the binary over SSH and runs it. Roughly forty lines, and it gives a real Windows signal immediately. Bazel remote execution with a Windows executor is the architecturally correct answer and is worth doing later, once the shim's overhead is what is slowing you down.

Do not use Wine. It emulates the OS, so a failure is ambiguous between our bug and Wine's bug, which defeats the purpose when the thing you are validating is ABI conformance.

## Building on Windows, later

This is milestone M6 and it is a separate body of work.

`bazelw` needs a PowerShell equivalent, since the existing one exits on any `$OSTYPE` that is not Linux or macOS, including Git Bash's `msys`. Bazelisk does publish a Windows binary, the script just never builds that string. `tools/bazel` needs one too, replicating the config enforcement and the bazelrc generation while dropping the Xcode and `/dev/shm` blocks. The three toolchain driver scripts should be rewritten in Python rather than PowerShell, since `rules_python` is already a dependency and one implementation then covers every platform.

Then there is Bazel on Windows itself. Assume `--features=compiler_param_file` is required rather than optional at this size. Set a short output root such as `--output_user_root=C:\b` from the start. Turn on long path support and Developer Mode, the latter so symlinks work without elevation. Exclude the source tree and the output root from Defender, because real time scanning a Bazel build is a large and completely silent tax. And the `Mojo/` against `mojo` case collision has to be fixed before any of this works on NTFS.

## Machines

The Linux build hosts and the Windows test machine are not named in this repository, by policy. Self hosted CI runners are referenced by opaque label only. If you are contributing, build on your own Linux box and test on your own Windows box.
