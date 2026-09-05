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

CI never needs one. The only Windows lane is analysis, which runs on a hosted Linux runner, gets the empty repository and does not care. Anything needing real Windows compilation is a manual step on a machine somebody owns, and `docs/releasing.md` says which steps those are. No CI job uploads a sysroot anywhere, and no CI job downloads one either.

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

### Which C runtime, and why static

The static release one, `libcmt.lib` with `libvcruntime.lib`, `libucrt.lib` and `oldnames.lib`, on both link paths.

The Bazel cross build gets there by not doing anything: `-fms-runtime-lib` defaults to the static release runtime and nothing in the toolchain changes it. Ask clang what it passes and it says `-defaultlib:libcmt -defaultlib:oldnames`. `mojo build` has to name the libraries itself, because a Mojo object file carries none of the `/DEFAULTLIB` directives a `cl.exe` object would, and for a while it named `msvcrt.lib`, which was wrong twice. That is the import library for the DLL runtime, so it disagreed with the runtime it said in a comment it was matching, and it is only the VC startup half, so a link naming it alone fails on `__acrt_iob_func` and every other UCRT symbol as soon as anything calls `printf`. Measured, not assumed: linking a `printf` hello world against `msvcrt.lib` and nothing else fails exactly that way.

All four libraries are needed because on this sysroot none of them pulls the others in. `libcmt` and `libucrt` without `libvcruntime` leaves `__C_specific_handler` undefined, which is the SEH personality routine, so it is not an obscure corner: any function with an unwind table wants it. And `oldnames` is the aliases from the POSIX spellings to the underscore ones, which the standard library needs because `std.io` calls `dup` and `fdopen` rather than `_dup` and `_fdopen`. Leaving it out fails in the standard library rather than anywhere that looks like a runtime problem, which is what makes it the easy one to miss.

The reason to pick static over dynamic is what a stranger has to install. The same hello world linked against the static set imports `KERNEL32.dll` and nothing else and comes to 120 kilobytes. Linked against the DLL set it is 9.5 kilobytes and imports `VCRUNTIME140.dll` and five `api-ms-win-crt-*` forwarders. The forwarders are in the box from Windows 10 onwards so those are free, but `VCRUNTIME140.dll` comes from the Visual C++ redistributable, which is on most machines and guaranteed on none. A hundred kilobytes per binary is a much better trade than a download and a reboot before anything runs, and it means the release zip is a zip rather than a zip and an installer.

It is also what `KGENCompilerRTShared.dll` already has inside it, so this is the choice that makes the two halves agree.

The thing static does not fix is handing a `FILE*` or a `malloc` pointer from the executable to the shared library, because two statically linked runtimes are two separate runtimes with two heaps and two stdio tables. That is #174 and it needs both sides on one dynamic runtime, which is a bigger change than this and not one to make before there is a reason.

Settling this is also what got `mojo build` linking end to end for the first time. Until now every Windows binary in this project came out of Bazel and the `mojo build` link line was only ever checked as a list of arguments. Given the four libraries above, the bundled `lld`, the Windows `KGENCompilerRTShared.if.lib` and the sysroot library paths, `mojo build --target-triple x86_64-pc-windows-msvc hello.mojo -o hello.exe` produces a 107 kilobyte executable that imports `KERNEL32.dll` and `KGENCompilerRTShared.dll`, and it prints when you run it on Windows. Nothing about that is wired up for a user yet, which is #27, but the path itself works.

### Where a Win32 import library gets named

Ten of them are named once, in the toolchain, in the Windows arm of `link_args` in `bazel/internal/cc-toolchain/args/BUILD.bazel`: advapi32, comdlg32, gdi32, kernel32, ole32, oleaut32, shell32, user32, uuid and winspool. That is the set `cl.exe` has linked by default since the mid nineties, and it is the same set Bazel's own MSVC toolchain uses. Third party Windows code assumes it is present and does not name these libraries, because on Windows nobody has to.

Everything else is named by the target that needs it, in its own `linkopts`, which is how `bcrypt` reaches mimalloc and `shlwapi` reaches google_benchmark. The line is there because we can edit our own targets and we cannot edit somebody else's. `@bazel_tools//src/tools/launcher` calls `RegGetValueW`, needs advapi32, and is not a file this repository can touch.

Two things to get right when you add one. The spelling is `-Wl,/DEFAULTLIB:foo.lib`. Without the `-Wl,` prefix, clang's GNU driver reads `-DEFAULTLIB:foo.lib` as `-D EFAULTLIB:foo.lib`, defines a macro nobody wanted, links without a word of complaint, and the library never reaches the linker. And the library has to exist in the sysroot under `sdk/lib/um/x86_64`, which for the SDK we pin means all ten of the above and most of the usual suspects besides.

## Running a Mojo program on Windows

There is one in the tree for exactly this purpose. From a Linux x86_64 host with the sysroot in place:

```
./bazelw build --config=build-mojo --config=windows \
  --repo_env=MOJO_WINDOWS_SYSROOT=/path/windows-sysroot.sh/printed \
  //Mojo/examples/windows-hello:hello
```

That produces `bazel-bin/Mojo/examples/windows-hello/hello.exe`, a PE32+ console executable, and building it involves cross compiling the Mojo compiler's own dependencies for the host, compiling the program with a Mojo compiler that runs on Linux, and linking the result against the MSVC runtime with `lld-link`.

`--config=windows` is two flags, the platform and `MODULAR_TARGET`, and the second one is easy to leave out because it looks redundant. It is not. Without it every tool the build needs on the way to the answer gets configured for the target rather than for the machine doing the work, so Bazel cross compiles the Mojo compiler to Windows and then tries to execute it, and what you see is a launcher complaining about network paths.

The executable is not standalone. It needs `KGENCompilerRTShared.dll`, `MSupportGlobals.dll` and `AsyncRTRuntimeGlobals.dll`, and Bazel puts all three next to it, so the whole of that directory is what you move to a Windows machine.

That is worth one sentence of why, because it is not how Bazel lays out a build anywhere else. PE has no rpath. The loader looks in the directory the executable is in, then in a short list of system directories, and then gives up, so a library one directory away is a library that is not there. The build turns on `copy_dynamic_libraries_to_binary` for Windows targets to put a copy of each one where the loader will look, which #146 did for `cc_binary` and #151 did for `mojo_binary`.

If you ever do end up running one of these without its DLLs, the symptom is nothing. A console process that cannot resolve an import exits with status zero and prints nothing at all, with no message and no dialog. It looks exactly like a program that ran and chose to say nothing.

## Testing a cross build

Bazel cannot natively run a Windows test from a Linux execution host. `scripts/run-on-windows.sh` is the shim that gets around that. It takes a Windows binary, puts it and the DLLs beside it on a Windows machine, runs it, gives you back its exit code and its output, and deletes what it copied. Hand it to Bazel as `--run_under`, or call it directly on a path.

```sh
./bazelw run --config=build-mojo --config=windows \
  --repo_env=MOJO_WINDOWS_SYSROOT=/path/windows-sysroot.sh/printed \
  --run_under="$PWD/../../scripts/run-on-windows.sh" \
  //Mojo/test/abi-conformance:frames
```

The machine comes from the environment and there is no default, which is the policy at the bottom of this page rather than an oversight. Set `MOJO_WINDOWS_TEST_HOST` to an ssh destination and it copies with `scp` and runs over `ssh`, staging under `C:\mojo-test` or wherever `MOJO_WINDOWS_TEST_DIR` points. Set `MOJO_WINDOWS_TEST_STAGE` instead, to a directory under `/mnt/` that the Windows side can see, and it uses WSL interop: the copy is a file copy and the run is executing the `.exe`, which WSL starts as a real Windows process and whose exit code it hands straight back. That second one is for when the Linux side doing the build is WSL on the same machine as the Windows side, which is a common enough way to have one machine do both jobs to be worth forty lines.

Neither transport is emulation. Both start the same PE on the same Windows kernel, and the only difference is how the bytes got there.

`bazel test` works through it as well as `bazel run`, and on the wsl transport it needs three flags that are not obvious. `--strategy=TestRunner=local` is one, because the sandbox mounts `/mnt/c` read only and staging into it fails as `mkdir: Read-only file system`. `--test_env=WSL_INTEROP --test_env=WSL_DISTRO_NAME` are the other two, because interop is a vsock to a server on the Windows side and those two variables are how a process finds it, so without them starting the executable times out as `UtilAcceptVsock:273: accept4 failed 110` and reads like a broken binary rather than a missing variable.

That same error has a second cause, and it looks identical. The vsock belongs to the WSL session that opened it, so a run started with `nohup` or `setsid` and then left to itself keeps working exactly as long as the session that launched it, and every test after that point fails the same way. A whole suite going from green to a couple of dozen passes and two hundred failures, all of them at about ten seconds, is this and not a regression. Run the Windows suites in the foreground of a session you keep open.

The shim carries a target's declared environment across, which is worth knowing because nothing about that is automatic. A fresh `cmd` starts with none of it, and WSL hands a Windows process only the variables named in `WSLENV`, so `export` on the Linux side is not enough and a test reading one gets an empty string. Under `bazel test` the whole of Bazel's environment travels minus a deny list of its own bookkeeping, which is safe because Bazel has already scrubbed the calling shell. Run by hand there is no scrubbing and the environment is your login shell, tokens included, so nothing is swept and `MOJO_WINDOWS_TEST_ENV` takes `NAME=VALUE` lines for what should cross. `MOJO_WINDOWS_TEST_VERBOSE` prints what was set.

What this is not is Bazel remote execution with a Windows executor, which is the architecturally correct answer and is worth doing once the shim's overhead is what is slowing you down.

Do not use Wine. It emulates the OS, so a failure is ambiguous between our bug and Wine's bug, which defeats the purpose when the thing you are validating is ABI conformance.

## Test tiers

A pass percentage over the standard library test suite is close to useless as a progress signal. The suite is dominated by tests that never touch the operating system, so the number mostly measures whether the ABI is right, it moves by a fraction of a percent when something real lands, and it says nothing about which part of the port is stuck. `test-tiers.txt` splits the suite into four tiers instead, and the signal is "tier 1 is green", which is a claim someone can check.

Tier 0 is pure computation. Tier 1 is the operating system surface this port is about. Tier 2 is what needs a second system to cooperate, meaning shared library loading, CPython hosting and process spawning. Tier 3 is deferred, which covers GPU targets and the POSIX interfaces that have no Windows meaning rather than a missing Windows implementation. The header of `test-tiers.txt` says which directory is in which tier and why.

```sh
scripts/test-tier.sh 0                        # run tier 0 for the host
scripts/test-tier.sh 1 --config=windows ...   # anything after the tier goes to Bazel
scripts/test-tier.sh 1 --print                # just the patterns, one per line
```

Tier 0 is the diagnostic and it is the reason the tiers are worth the trouble. Nothing in it asks the kernel for anything, so it passes on Windows for free once the ABI and the calling convention are right. If tier 0 is not green, the problem is not a missing Windows implementation of anything, it is the ABI, and no amount of porting library code will help.

## The pip lock file stays as it is

The build reads a `uv` lock file that covers Linux x86_64, Linux aarch64 and macOS arm64. `rules_pycross` turns it into one alias per wheel with one arm per environment the lock covers, so on a Windows configuration every one of those aliases has three arms and none of them match. Asking Bazel to analyze the whole tree for Windows produces 299 configurable attribute errors, and 209 of them are this.

We are not adding `win_amd64` to the lock, and the reason is that almost none of it is reachable from anything this port builds. Analysis of what we actually ask for, meaning the compiler plus tiers 0, 1 and 2, comes to 370 test targets, of which 357 analyze. Ten of the thirteen that do not are the numpy tests, `test_numpy.mojo` and `test_python_to_mojo.mojo`, once per supported Python version. The other three are the separate question of the prebuilt MAX wheel. Nothing else in the standard library suite reaches a pip wheel at all, and neither does the compiler.

So the cost of adding the environment is a regenerated lock, which `uv` is free to resolve differently for the platforms already in it, and the benefit is ten tests that need numpy on the target to say anything. That is the wrong trade while the milestone is about analysis. The wheels are for the Python side of MAX and for tests, not for building Mojo.

What we do instead is say so in the build files. The two numpy tests are marked incompatible with `//:windows_x86_64`, which is Bazel's own way of expressing "not on this platform" and makes them come back as skipped rather than as an analysis error. They still run everywhere else, which matters, because the Linux and macOS runs are where a numpy regression would actually be caught.

This is worth revisiting when there is a Windows build of MAX to test against, since at that point the Python side is in scope and the lock has to cover it anyway.

## The MAX wheel has no Windows arm either

The `modular_wheel` repository is the other half of the same shape. It is a handful of aliases onto prebuilt shared libraries lifted out of the published MAX wheels, and like the pip aliases each one has an arm per platform the wheel is published for, meaning Linux aarch64, Linux x86_64 and macOS arm64. There is no Windows wheel and there will not be one until MAX itself builds for Windows.

What is different is what a miss costs. A `select` with no matching arm stops analysis rather than skipping, and Bazel does not stop at the target that reached it. One standard library test importing `DeviceContext` pulls `AsyncRTMojoBindings_lib` into its package's `lit_tests_mojo_deps` aggregate, and the aggregate is what fails, so a whole package stops configuring for Windows on account of one test in it. That is where most of the old analysis allowlist came from.

So `bazel/modular_wheel_repository.bzl` gives every one of those aliases a default arm pointing at a `cc_library` marked `target_compatible_with = ["@platforms//:incompatible"]`. Bazel propagates incompatibility to anything that depends on it, so the tests that reach the wheel come back skipped, which is what they are, and the packages around them configure normally.

Sitting behind that was a bug of ours. `mojo_test_environment` walks the Mojo toolchain's implicit deps and stages each one's shared library next to the test, and the Windows toolchain puts two static libraries on that list, the compiler-rt builtins and the maths replacements. A static library has no `dynamic_library`, so the rule died on a `None` with a traceback that named neither the target nor the library. The loop immediately below it, over the deps that arrive through Mojo rather than through the toolchain, had always skipped static libraries. The toolchain loop now does too.

Between the two, `windows-analysis-allowlist.txt` is empty. See #223.

## Long paths use the prefix, not the manifest

Windows limits a path to 260 characters counting the drive letter and the terminator, and a directory to 248 so that an 8.3 name still fits inside it. That is a limit on the whole string rather than on any one name, so an ordinary tree that is deep enough runs into it with ordinary names in it, and a Bazel output tree is exactly that shape.

There are two ways out. Prefixing a path with `\\?\` turns off path parsing in the kernel and lifts the limit for that one call. Setting `longPathAware` in the application manifest, on a machine where the matching system setting is on, lifts it for the whole process.

We use the prefix. The manifest needs both halves to be in place and only one of them is ours: the system setting is off by default, it is per machine, and a program cannot do anything about it at the point it matters. A binary that works on the machine it was built on and fails on somebody else's is the worst kind of platform support, and that is what the manifest alone buys. The prefix works the same everywhere with nothing configured.

It goes on in `to_utf16` in `Mojo/stdlib/std/sys/_win.mojo`, which is the one place every path this library hands to Windows passes through. Doing it there rather than at each call site is the whole reason it is reliable, since the call sites that forget are the ones nobody writes a test for.

Three things about it are deliberate and none of them is obvious. The prefix cannot be put on the front of whatever the caller wrote, because turning off the parser means what follows has to be what the parser would have produced, so the path goes through `GetFullPathNameW` first to be made absolute and to have `.` and `..` taken out. It only goes on past 248 characters, not always, because the prefix changes what a path means as well as how long it can be: under it a device name is no longer a device and a trailing dot is no longer stripped. Below the threshold nothing needs the prefix, so nothing gets it, and paths of an ordinary length keep the behaviour this platform gives them. And the length that is measured is the length after the path is resolved, so a relative path is measured with the current directory in front of it, because working inside a deep tree with short names is the ordinary way to be in one and measuring the string as given is the one case that would still fail.

The prefix only helps a call that goes to Win32, and not everything did. The C runtime parses a path itself before it calls anything, and that parsing still has the limit in it and has never heard of the prefix, so `mkdir`, `rmdir` and `remove` now go to `CreateDirectoryW`, `RemoveDirectoryW` and `DeleteFileW` instead of to the narrow C runtime calls they used before. That was worth doing on its own account, since a narrow call also loses any character outside the current code page. `stat` is the one that could not simply be moved, because `_wstat64` invents permission bits and an execute bit from the extension that Win32 has no opinion about, so it stays and gains a fallback: when it fails, the name is looked up again through a handle before the failure is believed. Opening a file needed no change at all, because `_wopen` hands the name to `CreateFileW` as it stands.

What is still limited is the current directory, which the system caps at 260 characters no matter what any program does, so `chdir` into a tree deeper than that fails and there is nothing on this side to fix. Working inside such a tree with short relative names is fine, which is the case that matters.

The manifest is there as well now, as an addition rather than a replacement, for the parts of a Mojo program that never go through `to_utf16`, which is anything the C runtime or a linked in library does with a path of its own. The section below says how it gets in.

## The console gets set up on the first thing written to it

A console on Windows has two settings that decide whether a program's output arrives the way it was written, and both of them default to no.

The first is the code page, which is what the console reads bytes in. It defaults to whatever the system was set up with, which outside the English speaking world is usually not UTF-8 and on the machine this was written against is 437. Everything the standard library hands over is UTF-8, so without changing it a program that prints anything outside ASCII shows the wrong characters, and which wrong characters depends on where the machine came from. `SetConsoleOutputCP` and `SetConsoleCP` fix that, and both are called.

The second is escape sequences. Windows Terminal has them on already and the old console host does not, so the same coloured output renders in one and prints its own control codes as text in the other. `ENABLE_VIRTUAL_TERMINAL_PROCESSING` through `SetConsoleMode` turns them on, and the console is free to refuse, which is what happens on a version too old for it.

Both of these happen in `_prepare_console` in `Mojo/stdlib/std/sys/_win.mojo`, once, the first time anything is written to standard output or standard error. Not at startup, because a Mojo library loaded into a host process that never prints has no business changing the console it was loaded into, and both settings belong to the console rather than to the process, so they outlive the program the way `chcp` does. Every program that colours its output on Windows makes that same trade.

The answer to whether escape sequences work is also the answer to whether to colour anything, so `_use_color` in `Mojo/stdlib/std/utils/_ansi.mojo` asks the same function rather than asking `isatty`. On Unix `isatty` is the right question. On Windows it is not: a pipe is a character device and so is the null device, and both of them say yes, so a program whose output a shell redirected to a file would put escape sequences in it. Asking the console for its mode is the question that a file, a pipe and the null device all fail, which is what makes a redirect come out clean.

Both answers were checked on the machine with one program that prints `_use_color`, a line of non ASCII text and a green line. Run with output redirected to a file it reports `use_color: False` and the file holds `caf c3 a9 2d e6 97 a5 e6 9c ac` and `f0 9f a6 8b` for the emoji and not one escape byte. Run on a real console it reports `use_color: True`, the same UTF-8 bytes come out, and the green line is preceded by `1b 5b 39 32 6d`. So the console got both settings and the redirect got neither, which is the whole of what this is for. What is not settled by that is whether the colours look right to a person in cmd.exe and in PowerShell, and that is on the manual checklist in #29.

Paths with characters outside ASCII in them are checked by `Mojo/stdlib/test/os/test_non_ascii_path.mojo`, which creates a directory and a file with accented and Japanese characters and an emoji in their names, writes, reads, lists and removes them. The emoji is in there deliberately: it is a surrogate pair in UTF-16, so a conversion that counts characters instead of code units loses it, and that is a different bug from the code page one.

Separate from all of that is the application manifest with `activeCodePage` set to UTF-8, which is about the process rather than about the console, meaning the narrow Win32 and C runtime entry points and the command line a program is handed. That is the same manifest the long path section above wants, and the next section is about it.

## The manifest is a resource we write ourselves

Every executable `mojo build` links for Windows gets an application manifest embedded in it with three settings in it. `activeCodePage` makes the process code page UTF-8, `longPathAware` lifts the 260 character path limit on a machine where the matching system setting is on, and `requestedExecutionLevel` at `asInvoker` turns off installer detection, which is the heuristic that reads a file name and asks for elevation on finding `setup` or `update` or `patch` in it. There is deliberately no `compatibility` section listing supported OS GUIDs, because that changes what `GetVersionEx` reports and which shims the loader applies and is a separate decision nothing needs yet.

Measured on the machine rather than assumed: a probe built without the manifest reports `GetACP` 1252 and receives the argument `café-日本` as the bytes `63 61 66 e9 2d 3f 3f`, which is the accented letter transliterated and both Japanese characters replaced with question marks before the program starts. The same probe with the manifest reports 65001 and receives `63 61 66 c3 a9 2d e6 97 a5 e6 9c ac`, which is the string it was sent. That damage happens in the kernel on the way in, so there is no version of fixing it from inside the program.

The interesting part is how it gets in. The documented way is `/manifest:embed` with `/manifestinput:` on the link line, and it does not work here. LLD merges the file you give it with the one it generates, that merge goes through the XML support in LLVM, and an LLVM built without libxml2 does not have it and falls back to shelling out to `mt.exe`, which is not going to be on a Linux host. The `lld` in the MAX wheel is built without libxml2, and it is the one `mojo build` invokes, so it fails with `unable to find mt.exe in PATH`. The `lld-link` in the Bazel cc toolchain does have libxml2 and does merge, which matters only because it means the failure does not reproduce in the first place anybody would try it.

So `mojo-build.cpp` writes the resource itself. A `.res` file is a flat sequence of records, an empty one at the front and then one header and one blob per resource, everything padded to four bytes, and turning that into the `.rsrc` section of an image is in LLVM's object library rather than in its manifest code. Every COFF linker takes one as an ordinary input file, so the manifest goes to a temporary `.res` next to the temporary archive and onto the link line with no flag at all. Both linkers accept it.

Executables only. Everything in the manifest is a property of the process, and a DLL is loaded into a process whose properties were settled long before it arrived, so a manifest in one is read only for a COM isolation case this has nothing to do with. The lit test in `Mojo/test/mojo-tool/build/windows_target_link_line.mojo` pins both halves, the `.res` on the executable line and its absence on the shared library one, and it also has an `--implicit-check-not` on `/manifest:embed` and `/manifestinput:` so that a future change reaching for the obvious way gets told here rather than in somebody's install.

## Debug information ends up in a PDB

Compiling for Windows already produces debug information, and it is CodeView rather than DWARF. The object file for a five line program comes out with about 190 kilobytes of `.debug$S` and `.debug$T` in it, put there by LLVM because the target is `x86_64-pc-windows-msvc`. Nothing had to be added to make that happen and there was never a choice to make about the format.

What was missing was the link. A COFF linker only turns those sections into a `.pdb` if it is asked to, and `mojo build` never asked, so every Windows executable came out with all of it dropped at the last step. `/DEBUG` is the flag, and it now goes on the link line whenever `--debug-level` asks for debug information at all, which is the condition the dSYM generation on macOS already used. The linker names the file after the output, so `prog.exe` gets `prog.pdb` beside it. It has to travel with the executable, because that is the second place the system looks for it after the path recorded at link time.

Order matters on that line. `/DEBUG` changes what lld-link does by default about unused sections, from stripping them to keeping them, so `/OPT:REF` is passed after it and the size win stays.

What this buys is the stack trace printed on a fault. Every Mojo program installs one at startup, through `KGEN_CompilerRT_PrintStackTraceOnFault`, and on Windows that is LLVM's unhandled exception filter and it has always worked. It reads symbols through dbghelp, and dbghelp reads PDBs and nothing else, so without one a crash prints this:

```
about to fault
Exception Code: 0xC0000005
0x00007FF63F2C351A, C:\tmp\probe\test_crash_probe.mojo.test.exe(0x00007FF63F2B0000) + 0x1351A byte(s)
0x00007FF63F2B110F, C:\tmp\probe\test_crash_probe.mojo.test.exe(0x00007FF63F2B0000) + 0x110F byte(s)
0x00007FF63F2B25C0, C:\tmp\probe\test_crash_probe.mojo.test.exe(0x00007FF63F2B0000) + 0x25C0 byte(s)
0x00007FFE05E61363, C:\WINDOWS\System32\KERNEL32.DLL(0x00007FFE05E30000) + 0x31363 byte(s), BaseThreadInitThunk() + 0x13 byte(s)
0x00007FFE0762C580, C:\WINDOWS\SYSTEM32\ntdll.dll(0x00007FFE075C0000) + 0x6C580 byte(s), RtlUserThreadStart() + 0x20 byte(s)
```

and with one the same crash prints this:

```
about to fault
Exception Code: 0xC0000005
0x00007FF77845DCDA, C:\tmp\probe\test_crash_probe.mojo.test.exe(0x00007FF778410000) + 0x4DCDA byte(s), memset() + 0xBA byte(s), D:\a\_work\1\s\src\vctools\crt\vcruntime\src\string\amd64\memset.asm, line 196
0x00007FF77841110F, C:\tmp\probe\test_crash_probe.mojo.test.exe(0x00007FF778410000) + 0x110F byte(s), __mojo_main_prototype() + 0x10F byte(s), /Mojo/stdlib/std/builtin/_startup.mojo, line 185
0x00007FF778412650, C:\tmp\probe\test_crash_probe.mojo.test.exe(0x00007FF778410000) + 0x2650 byte(s), ?set_commode@__scrt_file_policy@@SAXXZ() + 0x160 byte(s)
0x00007FFE05E61363, C:\WINDOWS\System32\KERNEL32.DLL(0x00007FFE05E30000) + 0x31363 byte(s), BaseThreadInitThunk() + 0x13 byte(s)
0x00007FFE0762C580, C:\WINDOWS\SYSTEM32\ntdll.dll(0x00007FFE075C0000) + 0x6C580 byte(s), RtlUserThreadStart() + 0x20 byte(s)
```

The three frames that were addresses are now names, and two of them carry a source file and a line number. The exit code was right in both, `0xC0000005` reported as `-1073741819`.

Those are two runs of a program whose only content is a `memset` through a null pointer, so they are worth reading as a demonstration of the machinery rather than as a promise about every crash. The frame in the middle of a Mojo program is still named after whatever public symbol precedes it when that program's own frames were inlined away, which is what the third line is.

The binaries this repository's own Bazel build produces are linked by the toolchain rather than by `mojo build` and still have no PDB. Turning it on there is a separate decision, because a debug build's PDB is four megabytes per test executable and there are a couple of hundred of them.

## The CPU baseline for Windows is x86-64-v2

There are two CPU baselines in play here and they are easy to conflate. One is the instruction set the Windows compiler binaries in a release are built for, which decides what machine can run `mojo.exe` at all. The other is the default instruction set `mojo build` picks for the program a user compiles with it. They are set in different places and they do not have the same answer.

For the compiler itself the number is `x86-64-v2`, set in two places that have to agree: `--target-cpu` in the Mojo copts in `bazel/internal/BUILD.bazel`, and `-march` in the cc-toolchain in `bazel/internal/cc-toolchain/args/BUILD.bazel`. The Linux arms use `x86-64-v3` because Modular knows what machines those run on. Nothing is known about the machine a Windows release lands on, so this one is picked from the other end, which is the oldest hardware the support claim is willing to cover. `x86-64-v3` wants AVX2, so Haswell in 2013 on the Intel side and Excavator in 2015 on the AMD side, and the way a binary built for it fails on anything older is an illegal instruction with no message. `x86-64-v2` wants SSE4.2, POPCNT and CMPXCHG16B, so Nehalem in 2008 and Bulldozer in 2011. The claimed minimum is Windows 10 1809, which runs happily on Nehalem era hardware, so v3 would quietly contradict the support claim and v2 does not. Generic `x86-64` would have been the safe non-answer and it is not free, because POPCNT and SSE4.2 are exactly what a compiler's hashing and small string work uses, and a machine that cannot do v2 is a 2008 machine that is not going to be running a Mojo compiler.

For the code that compiler generates, the old answer was not a bad default so much as a bug. `CompilationOptions::setDefaultCPU` decided whether it was cross compiling by comparing the target architecture against the host architecture and nothing else. Windows x86_64 built on Linux x86_64 is the same architecture, so it took the native branch and baked in `llvm::sys::getHostCPUName()`. On the machine this was found on that meant `"target-cpu"="raptorlake"` in the module, with AVX2, AVX-VNNI, GFNI and SHA in the feature list, in a Windows executable whose entire reason for existing is that somebody else is going to run it. It would have faulted with an illegal instruction on anything older than the build machine, at whichever instruction happened to come first, which is about the least helpful failure a downloaded binary can have. The check now looks at the operating system as well, so a cross build gets no CPU name and LLVM uses the triple's own baseline. The feature list does not need clearing separately, because `mojo build` derives the features from the CPU name and an empty name gives the baseline set.

That leaves a program cross compiled for Windows more conservative than the compiler that built it, which is the right way round. Anyone who wants something else can still say `--target-cpu` or `--march`, and `--march=native` still means the host.

Fixing that turned up one thing hiding behind it. `test_issue_30237` in `Mojo/stdlib/test/builtin/test_simd.mojo` started failing on a Windows target, and the first reading of it was wrong. Nothing below `x86-64-v3` has an FMA instruction, so `SIMD.fma` on a float32 lowers to a call to `fmaf` in the C runtime rather than to an instruction, and the `fmaf` in the Windows UCRT is not always correctly rounded. Five triples were measured on Windows 11 and four came back matching a correctly rounded fused multiply add. The fifth was a whole ulp out, and it is not a near tie that could be argued either way: the exact result sits an eighth of an ulp from the value `fmaf` should return and seven eighths of an ulp from the value it does return. The double precision `fma` from the same library was right on all five, including the two written so that only the whole product would do. Linux at the same `x86-64-v2` makes the same call and passes, because the one in glibc is correct, and that is what made this look like a baseline problem when it is not. `bazel/internal/windows-math-fixups.c` supplies a correctly rounded `fmaf` for Windows targets, which is what the test now runs against. See #221.

## Starting Bazel on Windows

`bazelw` and `tools/bazel` are bash, and a Windows host has no bash to run them with. Both have a PowerShell counterpart as of #32, and so does the GPU detection script the wrapper calls.

`bazelw.ps1` asks for the `windows-amd64` bazelisk build, checks it with `Get-FileHash` rather than `shasum`, and skips the `chmod` because there is nothing to chmod. `tools/bazel-wrapper.ps1` does what the shell wrapper does: it refuses a `build`, `test` or `run` that has not chosen `--config=build-mojo` or `--config=prebuilt-mojo`, and it writes `build/wrapper.bazelrc`, which `.bazelrc` imports without a `try-import`, so a missing one is a hard error and not a default. The Xcode block and the `/dev/shm` sandbox base have no counterpart rather than a Windows translation, the first because it is macOS by definition and the second because there is no memory backed filesystem to point at. `bazel/internal/detect_local_resources.ps1` has only the nvidia-smi branch, since amd-smi and rocm-smi are Linux tools, so an AMD card on Windows reports no GPUs rather than a number that is wrong.

Both of those sit behind a `.bat`, which looks redundant until you try it the other way. Bazelisk looks for `tools/bazel`, then `tools/bazel.ps1`, then `tools/bazel.bat`. The first is skipped on Windows because it wants an executable bit that Windows does not report. The second is worse than skipped: bazelisk finds it, hands the path to `CreateProcess`, and `CreateProcess` cannot start a PowerShell script, so the run dies with `%1 is not a valid Win32 application` before the wrapper has said anything. That is why there is no `tools/bazel.ps1` in this repository. Shipping one would make bazelisk choose the path that does not work. The PowerShell half is called `bazel-wrapper.ps1`, a name bazelisk does not look for, and `tools/bazel.bat` is the shim that starts it.

The `.bat` does not pass the arguments on the command line. It puts the raw tail in an environment variable and `bazel/internal/windows-argv.ps1` splits it with `CommandLineToArgvW`. That is not defensive programming, it is a bug that was measured: `powershell -File wrapper.ps1 %*` does not parse its tail with the Windows rules, and the case it gets wrong is a quote that starts partway through a token, so `--test_filter="Foo Bar"` arrives as two arguments and bazel reports `Bar` as a target that does not exist. That spelling is what PowerShell itself produces when it passes an argument containing a space to a native program, so calling the `.bat` from a PowerShell prompt was enough to hit it. `-Command` would have parsed correctly and would also have expanded `$ORIGIN` in a linker argument to nothing, which is worse.

Which Bazel that gets you is its own question, because `.bazelversion` names `buildbuddy-io/5.0.382` and that release has darwin and linux assets and no Windows one. Bazelisk asks for `bazel-5.0.382-windows-x86_64.exe`, gets a 404, and stops before the build has started. Windows therefore runs the stock Bazel release the fork is built from, which `bazelw.ps1` sets through `USE_BAZEL_VERSION` and prints a line about, so it is never silent.

That release number was measured rather than inferred. The linux asset of `buildbuddy-io/5.0.382` answers `--version` with `bazel 9.2.0`, and stock 9.2.0 does publish a Windows build. So the Windows lane is the same Bazel release as every other lane without BuildBuddy's patches on top. The two alternatives were asking BuildBuddy to publish a Windows asset, which is not something this project controls, and building the fork for Windows ourselves, which is a binary to host and maintain forever. See #243.

The mapping is checked and not assumed. If the pin moves and `.bazelversion` names a different fork, `bazelw.ps1` stops and asks somebody to run that fork's linux asset with `--version` and write the answer down, rather than quietly running a Bazel nobody has looked at. A `.bazelversion` naming a plain version rather than a fork needs none of this and is passed through untouched, and an explicit `USE_BAZEL_VERSION` in the environment always wins.

The other Windows entry point is `bazelw.ps1` itself, run from a PowerShell prompt, which works because PowerShell parses your command line rather than the `.bat` doing it. `powershell -File bazelw.ps1 <args>` is the one spelling to avoid, for the reason above. Use `bazelw.bat` from a script.

## Building on Windows, later

This is milestone M6 and it is a separate body of work.

The three toolchain driver scripts were rewritten in Python in #33 rather than PowerShell, since the build already needs python3 on the host and one implementation then covers every platform. The wrappers above are PowerShell because they run before the build exists, on a machine that has PowerShell and may well not have Python.

## Bazel on Windows, what actually bites

#34 collected the Bazel on Windows problems that are usually described as inevitable, so that they could be planned for rather than met one at a time. With Bazel now startable on Windows the list can be checked instead of assumed, and most of it does not survive contact.

The setup for all of this: the reconstructed tree copied onto NTFS at `C:\m`, no WSL involved, `bazelw.bat --output_user_root=C:/b` for every invocation. Windows 11 26H1.

**Case insensitivity is not a problem at this pin.** The claim was that upstream has a `Mojo/` directory and README links to `./mojo` that collide on NTFS. A link in a README is not a file, so it never reaches the filesystem, and the tree itself is clean: of 10869 tracked files there is not one pair of paths that differ only in case, and not one pair of directories either. The copy onto NTFS is complete, `bazel query //:all` returns the whole root package, and analysis loads 125 packages before it stops for an unrelated reason. If a collision is introduced later it will be a new bug rather than this one.

**Path length is a problem and long path support is not optional.** With a four character output root, which is about as short as it gets, the longest path Bazel created was 296 characters, in the libcxx test suite inside a fetched repository. That is over `MAX_PATH` on its own, before any output path is derived from it. It worked because `LongPathsEnabled` is 1 on this machine. Turn that on, and keep the output root short anyway, because the margin it buys is spent immediately.

**Param files were not reached and are probably already handled.** Nothing has compiled on Windows yet, so the command line length limit has not been tested. What can be said is that the toolchain already turns on `archive_param_file` and `gcc_quoting_for_param_files` for every platform, so the archive and link sides are covered by construction. The compile side is the open question.

**clang-cl version parsing cannot apply.** Nothing here runs clang-cl. The toolchain uses clang in GNU driver mode on every platform, which is what the toolchain design decided long before this, so bazelbuild/bazel#17863 is not reachable from this repository.

**Symlinks are unmeasured.** Developer Mode is on on the test machine, so Bazel has permission to create them, and nothing has got far enough into a build for the convenience symlinks to appear. Whether the runfiles tree is symlinked or copied, and what that costs, is a question for the first build that finishes.

**Antivirus is still advice rather than a measurement.** Exclude the source tree and the output root from Defender. Real time scanning a Bazel build is a large tax and a completely silent one, so there is nothing to notice and nothing to attribute it to.

What did stop the build was not on the list at all, and there were three of them.

The first is fixed here. `.bazelrc` sets `--incompatible_strict_action_env` to keep `PATH` out of actions, which also gives a repository rule's subprocesses a fixed environment with no `SystemRoot` in it. On Windows a program that touches a socket needs `SystemRoot` to find the Winsock provider catalog, and Python is such a program without meaning to be: importing asyncio pulls in `_overlapped`, which initialises Winsock. rules_pycross runs pip inside a repository rule, pip imports asyncio by way of tenacity, and the whole thing fails with `WinError 10106`, "The requested service provider could not be loaded or initialized", which names neither Winsock nor the variable that is missing. `tools/bazel-wrapper.ps1` now writes `common --repo_env=SystemRoot=...` into the generated rc. That line is in the generated file rather than in `.bazelrc` because `.bazelrc` is shared with the Unix hosts, where the variable does not exist. Its backslashes are doubled, which looks like a detail and is the whole of the next paragraph.

The second is #248, which turned out to be the first one biting back. Bazel's rc parser treats a backslash as an escape character and drops it, so `common --repo_env=SystemRoot=C:\WINDOWS` arrives at the build as `SystemRoot=C:WINDOWS`. That is not a broken path, it is a drive relative one, so it resolves against whatever directory a subprocess happens to be started in and points at nothing. Quoting the value does not help, the parser eats the backslash inside quotes as well, and doubling the backslash is the only form that survives. What this broke was Bazel's own Windows SDK autoconfiguration, which writes a `get_env.bat` that calls `vcvarsall.bat` and runs it through a repository rule. With `SystemRoot` pointing at nothing that batch file printed the Visual Studio banner and then stopped dead, and the process sat there until the six hundred second timeout without ever starting a single child. It had `comctl32`, `UxTheme` and `urlmon` loaded, which is to say it was waiting on a shell dialog on a desktop nobody was looking at. Corrupting `SystemRoot` by hand reproduces the hang every time, and corrupting only `PATH` gives an empty answer rather than a hang, so the variable is the cause and not a symptom. With the backslashes doubled the fetch takes about twenty seconds and writes the three `rc.exe` wrappers it is meant to.

The third is #247 and was a real piece of work. Every `toolchain()` in `bazel/internal/cc-toolchain/BUILD.bazel` was registered with `exec_compatible_with` naming Linux or macOS, so with Bazel running on Windows nothing resolved and analysis failed with no matching toolchain for `@bazel_tools//tools/cpp:toolchain_type`. That is the boundary between a Windows host that can start Bazel and a Windows host that can build, and it is where native hosting actually begins.

It is fixed now, and the interesting part was not the registration. Adding a fourth execution platform meant fetching a clang that runs on Windows, which is the stock llvm-project release rather than one of Modular's builds because there is no Windows one of those, and it meant finding the selects that are keyed on the target platform and mean the execution platform. Which clang supplies the resource directory and the builtin headers is decided by the machine running clang, and those selects had been getting the right answer only because host and target always agreed. A Windows target can be reached from two different machines now, so they had to start asking the host. Bazel has no config setting for the execution platform, so asking the host means a repository rule reading `rctx.os.name`.

So the friction list turned out to be mostly folklore, the hang that looked like Bazel's fault was ours, and the toolchain that had never been asked to run on Windows has now been asked. What stops a Windows host today is two things further in. The pip lock file has three environments and none of them is Windows, so the mypy aspect that the rc turns on for every build cannot resolve its own dependencies, which is #252. Behind that, the three cc toolchain drivers are bare Python scripts and Windows has no shebang, so the first compile action will fail to launch until they get a launcher, which is #253.

## Machines

The Linux build hosts and the Windows test machine are not named in this repository, by policy. There are no self hosted CI runners and there is not going to be one, because attaching a machine you own to a public repository's pull request runs is a security decision rather than a piece of plumbing, and the thing it would buy is a Windows test lane we are content to run by hand. If you are contributing, build on your own Linux box and test on your own Windows box.

## What CI actually checks

Five jobs, all on GitHub hosted runners, all cheap.

`Lint` is shellcheck, actionlint and editorconfig. `House style` is two scans, one for private infrastructure and key material anywhere in the tree and one for punctuation we do not use. `Overlay` runs `scripts/check-overlay.sh`, which is the job that stops the overlay rotting against the pin. `CodeQL` is the usual.

`Windows analysis (x86_64)` is the only one that knows Windows exists. It reconstructs the tree, then runs Bazel analysis for the Windows platform over the compiler and over the tier 0 and tier 1 test patterns, and compares the set of targets that failed against `windows-analysis-allowlist.txt`. Nothing compiles and nothing links, which is what makes it affordable. It needs no sysroot, because the `sysroot-windows` repository rule is written to produce a valid empty repository when `MOJO_WINDOWS_SYSROOT` is unset, and analysis never looks inside it.

That gate is bidirectional on purpose. A target that starts failing fails the job, and a target in the allowlist that starts passing also fails the job, so the list cannot quietly go stale. Run it yourself with `scripts/check-windows-analysis.sh`.

The allowlist is empty as of #223. Every target in tier 0 and tier 1 analyzes for Windows, and so does the compiler, so anything that shows up in that job now is a regression rather than a gap.

What CI cannot do is run a Windows binary, and it is not worth pretending otherwise. That is a manual checklist against a release, and `docs/releasing.md` has it.
