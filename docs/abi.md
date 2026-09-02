# The Win64 ABI gap

This is the most dangerous thing in the project, so it gets its own document.

## What is wrong

`Mojo/lib/KGENToLLVM/CABILowering.cpp` decides which C calling convention to lower to. It looks at the target architecture and nothing else:

```cpp
switch (arch) {
case llvm::Triple::x86_64:
  // x86-64: Use System V AMD64 ABI (Linux, macOS, BSD)
  return std::make_unique<SystemVABIInfo>(ctx, dataLayout);
```

There is no check on the operating system. Point this at `x86_64-pc-windows-msvc` and it hands you System V lowering. The header already knows this is coming, there is a comment in `CABILowering.h` reading `/// - Future: Win64ABIInfo (Windows x64 calling convention)`.

## Why it is worse than it looks

Every other gap in this project fails loudly. A missing `select()` branch stops Bazel during analysis. A missing POSIX header stops the compiler. A wrong library extension produces a clear "cannot find libKGENCompilerRTShared.so".

This one produces a working build. The code compiles, links, and runs. It reads arguments out of the wrong registers and writes returns to the wrong place. What you see is wrong numbers, corrupted structs, and stack damage that shows up somewhere unrelated to the call that caused it.

The trap on top of that is that a large share of calls behave identically under both ABIs. Up to four integer arguments in the right positions, no aggregates, no floats mixed in, and System V and Win64 agree. So a test suite can be substantially green while the divergent cases are all broken. A pass rate is not evidence here.

## Where the two ABIs actually differ

| | System V AMD64 | Microsoft x64 |
| --- | --- | --- |
| Integer argument registers | RDI, RSI, RDX, RCX, R8, R9 | RCX, RDX, R8, R9 |
| Float argument registers | XMM0 to XMM7, counted separately | XMM0 to XMM3, aliased to the integer slot |
| Register or stack | classification per eightbyte | first four arguments only, then stack |
| Aggregates | classified, can go in two registers | by value only at exactly 1, 2, 4 or 8 bytes, otherwise a hidden pointer |
| Shadow space | none | caller reserves 32 bytes |
| Red zone | 128 bytes below RSP | none |
| Callee saved | RBX, RBP, R12 to R15 | that plus RSI, RDI, XMM6 to XMM15 |
| Vectors | in XMM registers | always by reference unless `__vectorcall` |
| Varargs floats | AL holds the XMM count | float duplicated into both the SSE and the integer register |
| `long` | 64 bit | 32 bit, this is LLP64 |

The aliasing rule is the one that catches people. On Windows, argument three is either R8 or XMM2 depending on its type, never both, and the slot is consumed either way. System V counts integer and SSE arguments on independent counters. So `f(int, double, int, double)` puts its arguments in completely different places under the two ABIs, and nothing about that is detectable at compile time.

## The fix

Add a `Win64ABIInfo` alongside `SystemVABIInfo` and make the dispatch look at the OS, not just the architecture. Write the dispatch as a decision over an architecture and OS pair rather than a binary choice between the two existing classes, because Windows on arm64 would be a third one later and there is no reason to make that a rewrite.

## The conformance suite

Do not write the lowering without the suite. Writing this code without a way to see its bugs means writing code whose bugs are invisible, and they will stay invisible until somebody hits one in a real program.

The suite is differential. For each signature, the same shape is compiled twice. Once by MSVC or clang-cl into a small C shared library that reports what it actually received in each register and stack slot. Once by Mojo, calling into that library through `external_call`. A mismatch is an ABI bug, pinned to one signature. Ground truth comes from the platform compiler, not from our reading of the specification, which is the whole point.

Cases to cover, each in argument positions one through six to catch the positional aliasing, and each as a return value:

1. Integer scalars of 8, 16, 32 and 64 bits.
2. `float` and `double` scalars. The highest yield case by far.
3. Mixed signatures such as `(int, double, int, double)`, which hit the aliasing rule directly.
4. Five or more arguments. Win64 starts spilling at five, System V at seven.
5. A struct of two 32 bit integers, 8 bytes. Both ABIs pass this in a register. It is the control case, it should pass before anything else does.
6. A struct of three 32 bit integers, 12 bytes. Win64 takes a hidden pointer, System V uses two registers.
7. A struct of two doubles, 16 bytes. Win64 takes a hidden pointer, System V uses XMM0 and XMM1.
8. A struct of one `float` and one `int`, where System V classification is subtle and Win64 only looks at the size.
9. Structs of 1, 2, 4 and 8 bytes against 3, 5, 6 and 7 bytes, since Win64 only passes by value at the exact power of two sizes.
10. Struct returns at all of the above sizes.
11. A signature containing C `long`, which is 32 bit on Windows and 64 bit on Linux. This also cross checks the standard library's `c_long` type.
12. `SIMD[DType.float32, 4]` against `__m128`.
13. Varargs, the `printf` family.
14. Shadow space, verified by having the callee write into it and checking the caller survives.
15. The callee saved register set, including XMM6 to XMM15.
16. Stack alignment with no red zone.
17. `bool` and `_Bool`, where the upper bit guarantees differ.
18. Nested and array containing structs, for recursive classification.

Run the suite on Linux against gcc or clang as well, targeting System V. Two reasons. It validates the harness itself against an ABI we know already works, before we trust it on an ABI we are implementing. And it catches regressions in shared lowering code, which is easy to break while adding a second ABI.

## The gate

No Windows binary is published until this suite is green. A toolchain that silently miscompiles is worse than no toolchain, because the bug reports it generates point everywhere except at the cause.
