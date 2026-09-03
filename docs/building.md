# Building

Nothing here produces a Windows binary yet. This document describes the approach and what it will take, so that the issues make sense. Milestone M3 is the first point at which any of it works.

## Get a working tree

```sh
./scripts/sync.sh
```

Upstream lands in `.upstream/modular` at the pinned commit with our overlay applied. Build from there. The first clone is large and slow, everything after that is not.

Always use `./bazelw` from inside that checkout rather than a system Bazel or a release tarball. The `tools/bazel` wrapper generates `build/wrapper.bazelrc` on every invocation, and `.bazelrc` imports it, so a tree where that wrapper has never run fails with a confusing message about a nonexistent path in an import declaration.

You also have to pass one of `--config=build-mojo` or `--config=prebuilt-mojo`. The wrapper enforces it. For this project it is always `build-mojo`, because `prebuilt-mojo` downloads a nightly wheel from Modular and there will never be a Windows one there.

## Say who built it

Every binary produced here has to identify itself as not being a Modular build. The overlay adds three Bazel settings for that, `//:downstream_id`, `//:downstream_build` and `//:downstream_upstream_commit`, all empty by default. Empty means the binary claims to be an ordinary Modular build, which for anything built here would be untrue, so pass them on every build:

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

**A sysroot.** Microsoft's CRT and Windows SDK headers and import libraries. Unlike the Linux sysroots, these cannot be mirrored, so we use `xwin`, which fetches them from Microsoft's CDN under the Visual Studio license. This one is done, and it has a section of its own below.

**Toolchain flags.** Add `x86_64-pc-windows-msvc` to the target triples. The existing GNU and Mach-O linker flags do not apply to COFF and need a parallel set. `-fPIC` is meaningless on PE, `-fvisibility=hidden` is a no-op since PE is hidden by default, which is why `SymbolExport.h` exists at all. Artifact name patterns for `.dll`, `.lib`, `.exp` and `.pdb` need adding.

Use `clang` in GNU driver mode with `--target=x86_64-pc-windows-msvc`, not `clang-cl`. Every existing flag in the toolchain is GNU style and switching driver modes would mean rewriting all of them. Clang's GNU driver targets the MSVC ABI perfectly well. Only the linker needs MSVC style arguments and that is `lld-link`'s job. It also sidesteps a known Bazel bug where `clang-cl -v` output is misparsed and Bazel looks in the wrong `lib/clang` directory.

The good news here is that this toolchain is built on the modern `rules_cc` Starlark API rather than legacy `unix_cc_toolchain_config`, and that API handles MSVC through the same primitives. The scaffolding is genuinely OS agnostic. Only the flag values are Unix shaped.

**Dependencies that have to be gated out rather than ported.** tcmalloc depends on glibc restartable sequences and Linux NUMA topology and has no Windows port, so it is replaced with mimalloc. libfabric, nixl, uccl, ucx, rocshmem and nvshmem are Linux and GPU cluster specific and are excluded. Crashpad is portable and upstream supports Windows properly, it just is not wired up here. grpc, protobuf, abseil, opentelemetry, asio, fmt, zlib-ng, zstd and the rest are fine as they are.

### A trap worth recognising early: the OS is not the driver

A third party BUILD file that writes `select({"@platforms//os:windows": ["/wd4127", ...]})` is not really keying on the operating system. It is keying on the driver, and it is assuming that a Windows target implies `cl` or `clang-cl`. For everyone else that assumption holds. For us it does not, because we deliberately use clang's GNU driver with an MSVC target, for the reasons two paragraphs up.

The GNU driver reads a leading slash as a path, so the first symptom is `clang: error: no such file or directory: '/wd4127'`, which reads like a missing file and is really a missing translation. zlib-ng was the first one of these. There will be more, and they will all look like that.

Two things make them worth a moment rather than a reflex. `--per_file_copt` cannot help, whatever it looks like, because it only ever adds flags and the problem is a flag that is already there. And the Windows arm of one of these selects is usually missing more than the suppressions: zlib-ng's was also missing the `-std=c11` that both other arms got, because whoever wrote it was thinking about cl, which does not need it. Read the whole arm rather than just deleting the slashes.

### Including windows.h

Nothing in this project includes `<windows.h>` directly. Include `Support/WindowsHeader.h` instead, and depend on `//Support:WindowsHeader`. It is safe to include unconditionally, because on any other platform it expands to nothing.

The reason for the indirection is that windows.h defines several hundred macros with names an ordinary program might want, and which of them it defines depends on macros you set before including it. `NOMINMAX` and `WIN32_LEAN_AND_MEAN` are the two that matter so far. That makes the header both order dependent and configuration dependent, and the failure mode is that everything works in every file until it does not work in one, and the file it breaks is usually not the file that got it wrong. One header, one place to decide, one place to explain why.

`NOMINMAX` is also passed by the toolchain, so it is set twice on purpose. The toolchain has to set it because it has to hold for code that never includes our header, all of boringssl for instance. The header sets it so that it is correct when read on its own, rather than correct only for as long as a BUILD file somewhere else keeps doing something.

## The Windows sysroot

Run this once per machine, and pass Bazel the flag it prints:

```
./scripts/windows-sysroot.sh
./bazelw build --config=build-mojo --repo_env=MOJO_WINDOWS_SYSROOT=/path/it/printed ...
```

It fetches `xwin`, checks it against a pinned hash, and has it pull the MSVC CRT and the Windows SDK from Microsoft's CDN into a `crt` and an `sdk` directory. About 630 MB for the x86_64 desktop variant, and a couple of minutes. Bazel picks it up through the `sysroot-windows` repository rule, which reads `MOJO_WINDOWS_SYSROOT` and does nothing useful without it.

It has to be `--repo_env` and not an exported shell variable. Upstream sets `--experimental_strict_repo_env` in `bazel/internal/common.bazelrc`, so a repository rule sees only what `--repo_env` hands it and nothing else from your environment. Exporting the variable and expecting Bazel to notice gets you the empty repository, and the empty repository is designed to be quiet, so what you actually see is every Windows header missing at once.

Doing nothing useful is the designed behaviour rather than a gap. With the variable unset the repository is empty but still valid, so analysis of a Windows configured build works on any machine and only a real compile action fails. That is the same trick the macOS sysroot rule uses, and it is what lets the cross build lane check the build graph on a runner that has no business downloading Microsoft headers.

### When it fails

Two failures are worth naming because neither error message points at the cause.

`Error: HTTP GET request for https://aka.ms/vs/17/release/channel failed, io: Network unreachable` means the machine has an IPv6 default route that does not work. The first request goes to `aka.ms`, which is IPv4 only, and succeeds. The redirect lands on a CDN host that has AAAA records, and xwin's HTTP client picks the IPv6 address and gives up when it fails. There is no happy eyeballs fallback, which is why `curl` on the same host works and this does not. WSL2 guests hit this often. Turn IPv6 off for the run and back on afterwards:

```sh
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
./scripts/windows-sysroot.sh
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
```

`Error: failed to retrieve ... after N tries due to I/O failures reading the response body` is an ordinary dropped connection partway through a few hundred files. The script already passes `--http-retry 5`, so if you are seeing this the link is bad rather than unlucky. Run it again, the download cache in `.xwin` is kept and it picks up where it stopped.

### Why the script is separate from the build

Running `xwin` accepts the Visual Studio license on the machine it runs on. A build system that quietly accepted a license for you the first time you typed `bazel build` would be doing something with legal weight as a side effect of something without any, so this is a script you run on purpose, once, and it says what it is doing while it does it.

### What we may and may not do with the result

Downloading it per machine is fine. That is the mechanism Microsoft ships and it is what the Rust ecosystem has done for years.

Mirroring the result into a public artifact store is not fine, and we will not do it. That rules out the obvious shortcut of splatting once and publishing a tarball next to the Jammy sysroots, which is why this is a repository rule reading a local path rather than an `http_archive` like its Linux siblings.

Copying a splat between your own machines is a question for whoever owns the license on those machines, and this project takes no position on it. The script is cheap enough to run per machine that the question does not need answering.

For CI the position is that any lane needing real Windows compilation runs on a self hosted runner that has run the script, or on a GitHub hosted `windows-latest` image, which already carries a licensed Visual Studio install and needs no sysroot at all because it has the real thing. Hosted Linux runners get the empty repository and the analysis only lane. No CI job uploads a sysroot anywhere.

### Proof it works

Worth writing down because the pieces are individually plausible and the combination is the thing that matters. On a Linux x86_64 host, with the toolchain clang the build already pins, which is 22.1.4:

```
clang++ --target=x86_64-pc-windows-msvc -fuse-ld=lld \
  -isystem $S/crt/include -isystem $S/sdk/include/ucrt \
  -isystem $S/sdk/include/um -isystem $S/sdk/include/shared \
  -L $S/crt/lib/x86_64 -L $S/sdk/lib/ucrt/x86_64 -L $S/sdk/lib/um/x86_64 \
  probe.cpp -o probe.exe
```

against a program including `windows.h`, `<cstdio>`, `<string>` and `<vector>`, calling `GetSystemInfo` and printing out of `std::vector<std::string>`. That produces a PE32+ console executable which runs correctly on Windows 11.

One version constraint fell out of that and it is worth knowing before you hit it. The MSVC standard library shipping today refuses to compile on anything older than Clang 19, with a `static_assert` in `yvals_core.h` that says so in as many words. The pinned toolchain is 22.1.4 so this never bites in a real build, but it will bite immediately if you reach for a distribution clang, and Ubuntu 24.04 ships clang 18.

## Linking

`lld-link`, bundled. It is what the Rust and clang-cl ecosystems use, it is mature, and bundling it means a user does not need a Visual Studio install to link, which is a real advantage over depending on `link.exe`. Keep `link.exe` selectable behind a flag in case a gap turns up.

Two things to check when wiring this up. `-Wl,--gc-sections` currently sits outside the `_WIN32` split in `mojo-build.cpp`, so on the Windows path it gets handed to a linker that does not understand it. The COFF equivalent is `/OPT:REF`. And the shared library path has no `/WHOLEARCHIVE:`, whose absence silently drops symbols out of static archives. Both are one line fixes once found, and both are good evidence that this code has never actually been run.

### Where a Win32 import library gets named

Ten of them are named once, in the toolchain, in the Windows arm of `link_args` in `bazel/internal/cc-toolchain/args/BUILD.bazel`: advapi32, comdlg32, gdi32, kernel32, ole32, oleaut32, shell32, user32, uuid and winspool. That is the set `cl.exe` has linked by default since the mid nineties, and it is the same set Bazel's own MSVC toolchain uses. Third party Windows code assumes it is present and does not name these libraries, because on Windows nobody has to.

Everything else is named by the target that needs it, in its own `linkopts`, which is how `bcrypt` reaches mimalloc and `shlwapi` reaches google_benchmark. The line is there because we can edit our own targets and we cannot edit somebody else's. `@bazel_tools//src/tools/launcher` calls `RegGetValueW`, needs advapi32, and is not a file this repository can touch.

Two things to get right when you add one. The spelling is `-Wl,/DEFAULTLIB:foo.lib`. Without the `-Wl,` prefix, clang's GNU driver reads `-DEFAULTLIB:foo.lib` as `-D EFAULTLIB:foo.lib`, defines a macro nobody wanted, links without a word of complaint, and the library never reaches the linker. And the library has to exist in the sysroot under `sdk/lib/um/x86_64`, which for the SDK we pin means all ten of the above and most of the usual suspects besides.

## Testing a cross build

Bazel cannot natively run a Windows test from a Linux execution host. Start with `--run_under` and a small script that copies the binary over SSH and runs it. Roughly forty lines, and it gives a real Windows signal immediately. Bazel remote execution with a Windows executor is the architecturally correct answer and is worth doing later, once the shim's overhead is what is slowing you down.

Do not use Wine. It emulates the OS, so a failure is ambiguous between our bug and Wine's bug, which defeats the purpose when the thing you are validating is ABI conformance.

## Building on Windows, later

This is milestone M6 and it is a separate body of work.

`bazelw` needs a PowerShell equivalent, since the existing one exits on any `$OSTYPE` that is not Linux or macOS, including Git Bash's `msys`. Bazelisk does publish a Windows binary, the script just never builds that string. `tools/bazel` needs one too, replicating the config enforcement and the bazelrc generation while dropping the Xcode and `/dev/shm` blocks. The three toolchain driver scripts should be rewritten in Python rather than PowerShell, since `rules_python` is already a dependency and one implementation then covers every platform.

Then there is Bazel on Windows itself. Assume `--features=compiler_param_file` is required rather than optional at this size. Set a short output root such as `--output_user_root=C:\b` from the start. Turn on long path support and Developer Mode, the latter so symlinks work without elevation. Exclude the source tree and the output root from Defender, because real time scanning a Bazel build is a large and completely silent tax. And the `Mojo/` against `mojo` case collision has to be fixed before any of this works on NTFS.

## Machines

The Linux build hosts and the Windows test machine are not named in this repository, by policy. Self hosted CI runners are referenced by opaque label only. If you are contributing, build on your own Linux box and test on your own Windows box.
