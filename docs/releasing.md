# Releasing

## What a version number means here

This project does not ship a product with its own feature set. It ships a set of changed files against a pinned upstream Mojo, so a version number needs to answer one question: how far through the roadmap is this. The scheme is built around the milestones rather than around semver's usual promises about API compatibility.

The rule is that `v0.x.0` marks the completion of milestone `Mx`, and `v0.x.y` for `y` greater than zero marks incremental progress made while working toward `M(x+1)`.

Read a version as "milestone x is finished, plus y batches of work since". So `v0.1.3` means M1 is done and three batches of M2 work have landed on top. That reads naturally and it sorts correctly, which are the only two things a version number has to do.

| Tag | Meaning |
|---|---|
| `v0.0.0` | M0 complete, the pin and the tooling work |
| `v0.0.1`, `v0.0.2` | progress during M1 |
| `v0.1.0` | M1 complete, a Windows targeted build passes analysis |
| `v0.1.1`, `v0.1.2` | progress during M2 |
| `v0.2.0` | M2 complete, the C++ compiles for Windows |
| `v0.3.0` | M3 complete, hello.exe runs |
| `v0.4.0` | M4 complete, tier 0 and 1 stdlib green |
| `v0.5.0` | M5 complete, first public release |
| `v0.6.0` | M6 complete, tier 2 and native hosting |
| `v0.7.0` | M7, which does not complete, so this one is not used |
| `v0.8.0` | M8 complete, handover or wind down |

There is deliberately no `v1.0.0`. Version 1 of Mojo on Windows is Modular's to ship, not ours, and claiming the number would be misleading about what this repository is.

## Patch releases

Cut one after a batch of pull requests has landed and the overlay still applies cleanly. There is no fixed cadence and no minimum number of pull requests. The test is whether somebody tracking the project would find the tag useful, which usually means a few related changes finishing something nameable rather than one change on its own.

Do not cut one when the only change is documentation or CI. Those land on `main` and get picked up by the next real release.

## Minor releases

Cut one when every issue in a milestone is closed and the milestone tracking issue's checklist is fully ticked. The milestone's exit criteria, written in the tracking issue under "Done when", have to actually be met and not just nearly met. If one item is outstanding, it is a patch release and the minor waits.

## What is in a release

Two sets of files, made in two different places.

The overlay archives, `mojo-windows-overlay-<version>.tar.gz` and `.zip`, are built by `.github/workflows/release.yml` when the tag is pushed. They hold `overlay/`, `scripts/`, `docs/`, the pin and the licence files, which is a complete and reproducible description of a tree: check out the tag, run `./scripts/sync.sh` and you have exactly what we had. Their checksums are in `SHA256SUMS` and they carry a provenance attestation.

The Windows archives, `mojo-windows-runtime-<version>-x86_64.zip` and the matching `-pdb.zip`, are built by `scripts/package-windows.sh` and uploaded to the draft by hand. Their checksums are in `SHA256SUMS-windows`. They are not attested, and the next section is why.

The point of tagging before there were binaries at all was that the overlay archives were already the useful artifact. That has not changed. The binaries are an addition, not a replacement.

## The Windows archives

Cross compiled from Linux, because there is no Windows build of the compiler yet. That is also why there is no `mojo.exe` in the archive: what a user can download today is the runtime a Mojo program needs and one program that uses it, and the toolchain arrives with native hosting in M6.

```sh
./scripts/package-windows.sh --version 0.4.2
```

That builds `//Mojo/examples/windows-hello:hello` for Windows with `--linkopt=-Wl,/DEBUG`, then lays the result out like this.

```
bin/hello.exe                 the example, cross compiled
bin/*.dll                     the runtime
lib/*.lib                     the import libraries
example/hello.mojo            the source bin/hello.exe was built from
LICENSE NOTICE README.txt upstream.lock
```

The DLLs sit in `bin/` next to the executable and not in `lib/` next to their own import libraries. That looks untidy and it is the only layout that works: Windows looks for a DLL beside the program before anywhere else and does not look in a sibling directory at all, so the tidy split produces an example that fails to start with `0xC0000135` and no message. That was tried, and finding out that way is the reason it is written down here.

Two files that are easy to lose and both are checked by the script rather than by eye. A shared library on Windows is a `.dll` and a `.lib`, and a packaging step written for a Unix `.so` drops the second without a word, so the script fails if an import library is not next to a DLL it is about to copy. Debug information goes in the separate `-pdb.zip` because a `.pdb` is several times the size of the binary it describes, so bundling them roughly quadruples a download that most people will never debug, and shipping none at all makes every crash report useless.

## Why the Windows archives have no provenance attestation

`actions/attest-build-provenance` signs a statement that a particular GitHub Actions workflow produced a particular file. For the overlay archives that statement is true and worth having. For the Windows archives it would be a lie, because CI does not build them and cannot: the build needs a Windows sysroot and a Bazel run measured in hours, well past what a hosted runner will do. Uploading locally built files into a workflow and attesting them there would produce a signature that verifies and a claim that is false, which is worse than no signature.

So what those archives get is checksums, the upstream pin inside the archive, and the release notes saying plainly where they were built. When native hosting lands and the build fits in CI, the attestation follows. Until then the honest thing is to say which files are attested and which are not, and the drafted release body does.

## The manual gate

CI does not run anything on Windows and is not going to. What a hosted runner can do is analysis, which is the `Windows analysis (x86_64)` lane, and that catches broken `select()` arms and toolchain drift for about ten seconds of compute. It cannot catch a miscompile, because building the compiler from source is hours and running the result needs a Windows machine. So the parts that need real hardware are a checklist somebody works through before publishing, not a check mark on a pull request.

Nothing here is optional for a release that contains binaries. Run all of it on a Windows machine, from a clean checkout of the tag.

1. The ABI conformance suite, `bazel test //Mojo/test/abi-conformance/...`, cross built and run on Windows. Green, no exceptions. This is the one that fails silently if it is skipped, which is the whole reason it exists. `Mojo/test/abi-conformance/README.md` explains what it covers and what it deliberately does not.
2. Tier 0 and tier 1, `scripts/test-tier.sh 0` and `scripts/test-tier.sh 1`, against the Windows configuration. Compare against the failures recorded for the previous release rather than against zero, and account for every difference in both directions.
3. The same two tiers on Linux, unchanged from the previous release. A Windows change that regresses Linux is a change that can never go anywhere.
4. `mojo build` on `Mojo/examples/windows-hello`, and run the result by double clicking it in Explorer rather than from a shell, because that is how the SmartScreen and antivirus behaviour shows up.
5. [The acceptance checklist](acceptance.md), which is the archive as a user gets it and the things only a person sitting in front of the machine can see. Record the result of every item, including the ones that cannot be checked yet.

Write the result of 2 and 3 into the release notes as counts. "Tier 0, 232 of 235" is a number the next person can diff against. "Tier 0 green" is not.

## Cutting one

Tag on `main`, push the tag, and the release workflow drafts the release. Fill in the notes and publish.

```sh
git tag -a v0.1.0 -m "M1 complete, a Windows targeted build passes analysis"
git push origin v0.1.0
```

If the release is meant to have binaries, build and attach them to the draft before publishing, from a checkout of the tag on a machine with a Windows sysroot.

```sh
./scripts/package-windows.sh --version 0.1.0
gh release upload v0.1.0 dist/mojo-windows-runtime-0.1.0-x86_64.zip \
  dist/mojo-windows-runtime-0.1.0-x86_64-pdb.zip dist/SHA256SUMS-windows
```

Then unpack the zip on a Windows machine and run `bin\hello.exe` from it before publishing. Not the one it was built on, if there is a choice, because that machine has the sysroot and everything else on it and is the least likely to notice a missing dependency.

## Release notes

Write them for somebody who has not read the pull requests. Lead with what changed about what the project can do, not with a list of commit subjects, and be honest about what still does not work. A release that says "the build now gets through analysis and immediately fails to compile, which is the next milestone" is more useful than one that lists eleven Bazel changes.

Always state which upstream commit the release is pinned to, because that is the thing that makes the tag reproducible.
