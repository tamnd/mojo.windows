# Win64 ABI differential conformance suite

The release gate for every Windows binary this project produces.

## Why it exists

The gap between the System V calling convention and the Win64 one fails silently. A Windows build that still lowers calls the System V way compiles, links, and runs, and a large fraction of calls behave the same under both conventions, so most of a test suite passes and tells you nothing. The bugs concentrate in the shapes people do not think to write down: a double in argument position three, a twelve byte struct, the fifth argument of anything.

A hand written expectation is no help here, because the thing being tested is exactly the thing you would have to be right about in order to write the expectation. So the suite does not contain expectations about registers at all.

## How it works

Every case exists twice. Once in C, in the `probe*.c` files, compiled by the platform C compiler and therefore following the platform ABI by definition. Once in Mojo, calling into that through `external_call`. The C side records what actually arrived in each argument position, the Mojo side asks for the recording back and compares it against what it sent. A mismatch is a lowering bug in the Mojo compiler, pinned to one signature and one argument position.

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

Struct arguments and struct returns, in `structs.mojo`. This is where the two conventions disagree most. Win64 looks at nothing but the size, so exactly 1, 2, 4 or 8 bytes goes in a register by value and everything else is copied to memory and passed as a hidden pointer that takes a register slot of its own. System V cuts the struct into eight byte pieces, classifies each piece by what is in it, and hands out up to two registers from whichever register files those pieces call for.

- Byte structs at every size from 1 to 8, which is four sizes Win64 passes in a register and four it does not.
- Structs of two and three 32 bit ints, two doubles, a float next to an int, two and three 64 bit ints, and a struct containing a struct.
- The same shapes with scalar neighbours before and after them, because a struct that lands in the right place while pushing its neighbour into the wrong one is still a broken call.
- Returns of every shape, which covers both the sizes that come back in registers and the sizes that come back through a hidden pointer the caller supplies.
- A layout agreement check that runs before any of it. Every shape is spelled out twice, and the suite means nothing if the two spellings are not the same shape, so the C side reports `sizeof` and Mojo compares against `size_of`.

C type widths and bools, in `widths.mojo`. The other two files ask where an argument lands. This one asks how many bytes it is before it goes anywhere, and it is the only part of the suite where the two platforms are supposed to give different answers.

Worth knowing before reading it: on x86-64 a wrong width mostly does not show. Every argument takes a full eight byte slot whatever it is, in a register or on the stack, and the callee reads the low end of the slot, which is where a small number lives. Setting `c_long` to 64 bits on Windows and running this file leaves every value check in it passing. Only the direct width comparison catches it. That is why the widths get a check of their own rather than being something the value tests would have found anyway.

- The width of `char`, `short`, `int`, `long`, `long long`, `size_t`, a pointer and `bool`, each against `sizeof` from the C side rather than against a number written down here.
- Whether plain `char` is signed. Not a width, but the other thing the data model leaves open. It is signed on x86-64 Windows and Linux both and unsigned on ARM Linux, so it starts earning its keep at the arm64 port.
- `long` six at a time, nine at a time so three of them spill, next to types whose width is fixed, and with negative values so that a caller which zero extends where it should sign extend is caught. `long long` gets the same treatment as a control.
- Bools six at a time, between wider arguments, and past the register file where a caller that packed them into less than a full stack slot would be visible. Plus the raw byte a bool arrives as, which is the weakest check here because the C compiler is allowed to normalise it and hide a bad caller.

## What is not covered yet

`SIMD[DType.float32, 4]` against `__m128`, varargs, shadow space, the callee saved register set including the extra XMM registers Win64 preserves, stack alignment with no red zone, and structs containing arrays. Issue #13 tracks the rest.
