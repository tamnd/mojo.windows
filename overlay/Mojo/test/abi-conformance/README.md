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

Variadic calls, in `varargs.mojo`. The one place the callee cannot see the signature, and the two conventions deal with that in opposite ways. Win64 hardly changes anything, except that a floating point variadic argument goes into the SSE register and into the integer register sharing its slot, because the callee walking a `va_list` reads the integer one. System V changes a lot: the callee spills the argument registers into a save area, and decides how many SSE registers to spill by reading AL, which the caller has to set to the number of vector registers it used.

- Integers, doubles, and the two alternating, six at a time.
- Eight doubles, which uses every SSE register either convention hands out and is where a wrong AL does the most damage.
- Twelve integers, so the list runs off the end of the register save area and `va_arg` starts reading the caller's stack.
- The default argument promotions, which are the caller's job: anything narrower than an int becomes an int and a float becomes a double.
- A variadic call that returns a value, since none of the others do.
- `snprintf` from the platform C runtime, which is the case that actually has to work. Everything else in this suite is a probe written alongside the test and compiled with the same assumptions. The C runtime shares neither, and it is what real code reaches for. C makes the same call into a buffer of its own and the two are compared, rather than comparing against a literal, because how a platform renders a double is not the thing under test.

Vectors, in `vectors.mojo`. The sharpest disagreement left. System V gives a sixteen byte vector a class of its own and passes it in an SSE register. Win64 has no such class and nothing it considers wide enough, so the vector is copied to memory and passed as a pointer, and it comes back through a hidden pointer the caller supplies. This is not a special case of the struct rules: sixteen bytes of two doubles in a struct and sixteen bytes of two doubles in a vector are the same size and System V treats them differently, which the fault injection below confirms.

- `SIMD[DType.float32, 4]`, `SIMD[DType.float64, 2]` and `SIMD[DType.int32, 4]` against the matching `vector_size(16)` types in C, all three sixteen bytes and all three the same class, since both conventions classify by width rather than by element type.
- Two vectors, a vector with scalars after it, scalars with a vector after them, and five vectors so the last of them are on the stack under both conventions and by different arithmetic.
- Returns, including a return from a call that has already spent its register slots, which is where the hidden pointer and the arguments compete for the same places.

## What is not covered yet

Shadow space, stack alignment with no red zone, the callee saved register set including the extra XMM registers Win64 preserves, structs containing arrays, and a struct containing a C `long`. The register set is the one that needs C to call into Mojo rather than the other way round, which needs COFF exports and is issue #134. Issue #13 tracks the rest.
