## What this changes

<!-- One or two sentences. -->

## Why

<!-- What is broken without it. Link the issue. -->

Closes #

## Checklist

- [ ] Each commit is one logical change with a subject line starting `build:`, `compiler:`, `runtime:`, `stdlib:`, `test:`, `bazel:` or `docs:`
- [ ] Commits are signed off with `git commit -s`
- [ ] `./scripts/refresh.sh` has been run and `overlay/` is up to date
- [ ] The Linux and macOS test suites still pass, or it is explained below why they were not run
- [ ] No machine name, host name, IP address or credential appears anywhere in the change
- [ ] If this touches the ABI lowering, the conformance suite passes

## Can this go upstream as is

<!--
Standard library changes and pure portability refactors can be offered to Modular today.
Compiler changes get banked until they are taking them. Say which this is.
-->
