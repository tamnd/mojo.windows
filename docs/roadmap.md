# Roadmap

Estimates are in engineer weeks for one experienced systems person who is comfortable with LLVM, MLIR, Bazel and the Win64 ABI, and who has already read the documents in this directory. They are planning numbers with wide error bars, not commitments.

The dominant uncertainty is not any single item. It is the long tail of small breakages that only become visible once the blocker in front of them clears, and that is unmeasurable in advance. Expect the first `hello.exe` to take longer than a naive schedule says and everything after it to go faster.

Each milestone has a tracking issue holding the checklist of work under it, so live progress lives there rather than in this file. They are [#47 through #55](https://github.com/tamnd/mojo.windows/issues?q=is%3Aissue+label%3Atype%2Fepic), one per milestone, and the [milestones page](https://github.com/tamnd/mojo.windows/milestones) has the same thing as percentages.

## M0, upstream pin established, half a week

Get the repository and the pin set up, confirm a clean upstream Linux build and a green upstream test suite, and put the unofficial build identification and the disclaimer in place. That green Linux build is the baseline every later change gets measured against, so it is worth doing properly rather than assuming.

Also do the boring prerequisites now, specifically making sure the Windows test machine has enough free disk for a Bazel and LLVM build. It costs an hour and it removes a dependency that would otherwise silently stall M6.

## M1, build analysis passes for a Windows target, one and a half to two and a half weeks

Pure Bazel work, nothing runs. The goal is that a Windows targeted build gets past analysis and starts issuing compile actions, so that failures are compile errors rather than `select()` resolution errors.

Add the platform and constraints, fix `Support/BUILD.bazel` which is the first thing that will break, gate out the Linux only dependencies, and work through the 276 OS keyed select sites across 91 files. The sweep is the bulk of the time. It is mechanical but it is wide, and the aim is to make everything resolve rather than to make everything build. Where a target genuinely does not apply, mark it incompatible, which is already the established pattern in the tree.

Also answer the elaborator question here, before committing to the M2 and M3 chain. See the risks section below.

## M2, the C++ compiles, three to five weeks

The sysroot, the toolchain flags, the driver script branches, and then the grind. Semaphore will not compile under MSVC at all. tcmalloc gets replaced. Every `#include <unistd.h>` and every GCC attribute in a million lines of C++ surfaces here, one build error at a time.

Highest variance milestone by a distance. It could be two weeks and it could be ten. Start the sysroot work first because it has a licensing question attached and that needs lead time.

## M3, hello.exe, two to four weeks

The first milestone with something you can run.

The Win64 ABI implementation and its conformance suite, the target registries, rewiring the linking in `mojo-build.cpp` from host driven to target driven, the COFF flavour for the offload linker, unifying the shared library extension, the compiler runtime as a DLL, and `is_windows()` in the standard library, which has to land before anything else can branch on the platform.

The ABI implementation and the conformance suite are one piece of work. Do not split them across people or across weeks. Writing the lowering without the suite means writing code whose bugs are invisible.

Exit condition is that `mojo build hello.mojo` on Linux produces a `hello.exe` that runs on Windows, and that the conformance suite is green.

## M4, tier 0 and tier 1 standard library green, four to six weeks

The standard library items. Highest leverage first: `DLHandle`, which unlocks around 150 CPython bindings in one change, then `c_long` which is an outright compile blocker under LLP64, then file descriptors, the errno table, path and drive letter handling, and the process spawning rewrite.

Tier 0 is pure computation, `builtin`, `math`, `memory`, `collections`, `bit`, `hashlib`, `utils`, `algorithm`. Only 36 of 249 standard library files touch POSIX at all, so tier 0 should pass essentially for free once M3 lands. If it does not pass at the start of M4, the ABI is wrong. Stop and go back.

Tier 1 is `os`, `pathlib`, `sys`, `time` and file I/O.

Track progress as "tier N green" rather than as a pass percentage. A percentage is dominated by the trivial tier 0 mass and hides real progress.

The tiers are written down in `test-tiers.txt` and run with `scripts/test-tier.sh`, so the claim is checkable rather than a description. That file is also where the exact membership lives, including the handful of individual files that sit in a tier their directory does not.

## M5, first public release, one to two weeks

Console virtual terminal handling, the UTF-8 manifest, wide character paths, the crash handler, then packaging. A zip on GitHub Releases with checksums and build provenance. PDBs generated and published separately. Release notes that say plainly what does not work.

This is the point of the project. Everything after it is refinement.

## M6, tier 2 and native hosting, four to seven weeks

Two independent tracks, so this is where a second person actually helps.

One track is correctness: Python interop end to end, subprocess, console behaviour, and the COFF JIT, which is what the REPL and `mojo run` need. That JIT work is the largest single unknown in the plan.

The other track is native hosting: the PowerShell bootstrappers, rewriting the driver scripts in Python, and all the Bazel on Windows friction.

## M7, steady state, ongoing

Full CI lanes, a rebase cadence, and upstreaming the portable subset. Additional distribution channels only if somebody actually asks for them, because every channel added is a channel that has to be wound down later.

## M8, handover or wind down

Not a schedule item, a posture. When Modular and Microsoft ship official Windows support, send what can be sent and archive the rest. This project is meant to become unnecessary.

## Summary

| Milestone | Estimate | Cumulative | Gate |
| --- | --- | --- | --- |
| M0 upstream pin established | 0.5w | 0.5w | Linux build green from the pin |
| M1 analysis passes | 1.5 to 2.5w | 2 to 3w | no select failures |
| M2 C++ compiles | 3 to 5w | 5 to 8w | mojo.exe links |
| M3 hello.exe | 2 to 4w | 7 to 12w | ABI suite green |
| M4 tier 0 and 1 | 4 to 6w | 11 to 18w | tiers green, Linux unregressed |
| M5 first release | 1 to 2w | 12 to 20w | acceptance checklist |
| M6 tier 2 and native host | 4 to 7w | 16 to 27w | REPL and native Bazel |

Roughly three to five months to a usable first release for one person, four to seven to M6. With two people, M2's grind and M4's standard library work parallelise well and M6's two tracks are genuinely independent, so call it two and a half to four months to M5. It does not go below that. M1 to M2 to M3 is a hard serial chain and the ABI work has to be one person's.

Three or more people does not help before M4. Adding them to M2 mostly produces merge conflicts in the same files.

## If you only want a demonstration

There is a materially shorter route. M0 through M3 only, cross compiled, no native hosting, no standard library beyond tier 0, no packaging. That produces "Mojo compiles a working Windows executable" in about seven to twelve weeks and settles all the interesting technical questions.

Worth naming explicitly, because M4 through M6 is more than half the total effort and what it buys is completeness rather than proof.

## Where this plan is most likely to be wrong

**The COFF JIT might need real upstream LLVM work.** ORC's COFF support is the least mature of the three object formats and there is already a FIXME in the tree from somebody who hit this and stopped. If it turns out to need LLVM changes it is a multi month item on its own. It is kept off the critical path deliberately, since it blocks the REPL but not `mojo build`, and M5 ships without it.

**The elaborator might need to JIT target code. Answered, and the answer is no.** This was the assumption whose failure would most have reordered the plan, so it was checked first. Compile time evaluation runs on `BytecodeInterpreter`, which walks IR and takes the target only to pick a data layout. It never executes native code and has no escape hatch that does. The one place the elaborator can reach a compiler is `compileAsmFn`, reachable only from the `compile_assembly` intrinsic, and that emits an object for an offload device with `isJIT=false` rather than running anything. `mojo build` never constructs an execution engine at all. See #3 for the full read. The COFF JIT stays in M6 where it was, blocking the REPL and `mojo run` and nothing else, and cross compiling first holds.

**M2's long tail is unquantifiable by construction.** The three to five week range is the honest expression of that rather than a considered estimate.

**The sysroot licensing question could block CI** even though it will not block development. Start it early so the answer arrives before it matters.
