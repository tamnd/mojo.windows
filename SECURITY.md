# Security Policy

## Scope

This repository contains patches, build scripts and documentation. It does not vendor upstream source and, until milestone M5, it does not publish binaries.

If you have found a vulnerability in Mojo itself that reproduces on Linux or macOS with plain upstream, please report it to Modular rather than here. Report it here if it is introduced by one of our patches, is specific to the Windows target, or is in our build or release tooling.

## Reporting

Use [private vulnerability reporting](https://github.com/tamnd/mojo.windows/security/advisories/new). Please do not open a public issue for a security problem.

Include the pinned upstream commit from `upstream.lock`, which patches were applied, and how to reproduce. We will acknowledge within a week. This is a small volunteer project, so please set your expectations accordingly, and if something is not moving, say so on the advisory thread.

## Binaries, once there are any

From M5 onward, releases are published on GitHub Releases with SHA-256 checksums and build provenance attestation. Verify a download before running it:

```sh
gh attestation verify mojo-windows.zip --repo tamnd/mojo.windows
```

Release binaries are not code signed. That means Microsoft Defender SmartScreen will warn about an unknown publisher, and heuristic antivirus may flag the compiler, because a JIT capable compiler that writes and executes memory looks a lot like the behaviour those heuristics are built to catch. This is expected and is documented on each release. It is also exactly why the checksums and the attestation exist, so please use them rather than assuming a missing warning means a file is fine.

We do not currently have the budget for a code signing certificate. If the project gets real traction that will be revisited.

## Threat model, stated plainly

A compiler toolchain runs arbitrary code from the source it compiles, by design. Do not compile untrusted Mojo source on a machine you care about. Nothing in this project changes that.
