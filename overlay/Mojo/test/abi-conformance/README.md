# Win64 ABI differential conformance suite

The release gate for every Windows binary this project produces.

## Why it exists

The gap between the System V calling convention and the Win64 one fails silently. A Windows build that still lowers calls the System V way compiles, links, and runs, and a large fraction of calls behave the same under both conventions, so most of a test suite passes and tells you nothing. The bugs concentrate in the shapes people do not think to write down: a double in argument position three, a twelve byte struct, the fifth argument of anything.

A hand written expectation is no help here, because the thing being tested is exactly the thing you would have to be right about in order to write the expectation. So the suite does not contain expectations about registers at all.

## How it works

Every case exists twice. Once in `probe.c`, compiled by the platform C compiler, which therefore follows the platform ABI by definition. Once in Mojo, calling into that through `external_call`. The C side records what actually arrived in each argument position, the Mojo side asks for the recording back and compares it against what it sent. A mismatch is a lowering bug in the Mojo compiler, pinned to one signature and one argument position.

Ground truth comes from the platform compiler rather than from anyone's reading of the specification, and that is the whole point. It also means the suite is useful the moment it is written, with no separate exercise to work out what the right answer is.

The probes record rather than echo. Echoing an argument back through the return value is the obvious design and it is worse: it reports only the first thing that went wrong, and it puts the argument path and the return path in the same test so a failure does not say which one broke. Recording separates them. The return path gets its own family of probes that take one argument and return one value.

## Running it

```
bazel test //Mojo/test/abi-conformance/...
```

That builds for the host, which on Linux means the suite is checking System V. Worth doing on its own account: it validates the harness against a convention that already works before anyone trusts it on one that is being implemented, and it catches regressions in the lowering code that both conventions share, which is easy to break while adding the second one.

Cross building it for Windows works the same way as anything else, and `docs/building.md` in the repository root has the flags. Running the result needs a Windows machine, which is issue #22.

## What is covered so far

Scalar arguments and scalar returns, in `scalars.mojo`.

- Integer scalars of 8, 16, 32 and 64 bits, six at a time, with negative values so that a lowering which relies on the upper bits of a register being clean is caught. Neither convention promises anything about those bits.
- `float` and `double` scalars, six at a time.
- One `double` among integers at each of the six argument positions, and one integer among doubles the same way, and the narrow version of both with `float` against 32 bit integers. This is the highest yield family in the suite. Win64 numbers the integer and SSE register files together, so a double in position three takes XMM2 and leaves RDX unused, while System V numbers them separately, so the same double takes XMM0 and the integers stay packed into the first three integer registers.
- Alternating mixed signatures, which is what real code looks like.
- Nine arguments, which is past the register file under both conventions. Win64 spills from the fifth argument whatever its type, System V spills from the seventh integer and the ninth float counted separately, so the split between registers and stack is different on the two platforms and the stack half is only checked by running it.
- Returns of each scalar type, including returns from calls that have already used up the register file.

## What is not covered yet

Structs of every interesting size and shape, struct returns, C `long` which is 32 bits on Windows and 64 on Linux, `SIMD[DType.float32, 4]` against `__m128`, varargs, shadow space, the callee saved register set including the extra XMM registers Win64 preserves, stack alignment with no red zone, and the upper bit guarantees on `bool`. Issue #13 tracks the rest.
