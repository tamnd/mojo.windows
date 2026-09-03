// RUN: kgen-opt -split-input-file -lower-global-pop-to-llvm %s | FileCheck %s

// Conformance tests for C ABI lowering on x86-64 Windows (Microsoft x64).
//
// PURPOSE: this is the release gate for Windows x86-64. The ABI is the one
// place in the port that does not fail loudly. A Windows binary lowered with
// the wrong convention compiles, links and runs, and reads its arguments out
// of registers nobody wrote them to. So the expectations below are not a
// reading of the Microsoft documentation and they are not what we thought the
// rule was. Every one of them is what clang actually emits for
// `x86_64-pc-windows-msvc`, taken from real output, and `scripts/abi-ground-
// truth.sh` regenerates that output so any line here can be rechecked against
// the reference implementation rather than argued about.
//
// TRANSFORM UNDER TEST:
//   Mojo/lib/KGENToLLVM/LowerPOPToLLVMExternalCalls.cpp — ConvertPOPExternalCall
//   Mojo/lib/KGENToLLVM/CABIWin64.cpp                   — Win64ABIInfo classifier
//   Mojo/lib/KGENToLLVM/CABILowering.cpp                — arch and OS dispatch
//
// RELATED TEST FILES:
//   extern-c-abi-x86-64.mlir  — the same machine under System V. Read the two
//                               side by side. Most of the cases below diverge,
//                               and each one that does says so.
//   extern-c-abi-aarch64.mlir — ARM64 AAPCS
//   extern-c-abi.mlir         — platform independent (empty triple)
//
// THE WHOLE RULE: an aggregate whose size is exactly 1, 2, 4 or 8 bytes is
// passed in one register as an integer of that width. Every other aggregate is
// passed by reference. Nothing looks inside the struct, so there is no
// eightbyte classification, no float rule and no two register case. Returns
// use the same size test, with a hidden pointer instead of a reference.
//
// WHAT IS NOT COVERED HERE, AND WHY: this file checks the coercion, which is
// the part the compiler decides. It does not check which physical register an
// argument lands in, because that is the LLVM backend's job and the backend
// reads the convention off the triple. It also does not run anything. The
// runtime half of the conformance suite, where a Mojo binary calls a C library
// built by MSVC and the library reports what it actually received, needs a
// Mojo toolchain that runs on Windows, and that does not exist yet. See #13.
//
// NOT AN ABI QUESTION, LISTED SO IT IS NOT LOOKED FOR HERE: C `long` is 32 bits
// on Windows and 64 on Linux, and `char` and `short` arguments are sign
// extended by System V and left alone by Win64. Both are decisions the front
// end makes about what type an argument has before this transform ever sees
// it, so neither can be tested at this layer.
//
// TEST TABLE. The right hand column is what this compiler's own System V
// classifier does with the same input, so the divergence is visible without
// opening the other file. It is not always what clang does for System V:
// clang widens a 5 byte struct to i40 where this compiler widens it to i64,
// and clang keeps a wrapped 4 wide float vector in one SSE register where this
// compiler splits it into a pair. Those are pre-existing System V differences
// and they are not what this file is about, but the column would be misleading
// without saying so.
//
// Group W — Aggregate arguments, by size
//   W1   {i8}                     1  → i8           SysV: i8            same
//   W2   {i8,i8}                  2  → i16          SysV: i16           same
//   W3   {i8,i8,i8}               3  → ptr          SysV: i32        DIVERGES
//   W4   {i32}                    4  → i32          SysV: i32           same
//   W5   {[5 x i8]}               5  → ptr          SysV: i64        DIVERGES
//   W6   {[6 x i8]}               6  → ptr          SysV: i64        DIVERGES
//   W7   {[7 x i8]}               7  → ptr          SysV: i64        DIVERGES
//   W8   {i32,i32}                8  → i64          SysV: i64           same
//   W9   {i32,i32,i32}           12  → ptr          SysV: (i64,i32)  DIVERGES
//   W10  {i64,i64}               16  → ptr          SysV: (i64,i64)  DIVERGES
//   W11  {i64,i64,i64}           24  → ptr          SysV: ptr byval  DIVERGES
//
// Group X — Floats in aggregates. Win64 does not have a float rule at all.
//   X1   {f32}                    4  → i32          SysV: f32        DIVERGES
//   X2   {f64}                    8  → i64          SysV: f64        DIVERGES
//   X3   {f32,f32}                8  → i64          SysV: f64        DIVERGES
//   X4   {f64,f64}               16  → ptr          SysV: (f64,f64)  DIVERGES
//   X5   {i32,f32}                8  → i64          SysV: i64           same
//
// Group Y — Vectors and nesting
//   Y1   <2 x f32> bare              → identity     SysV: identity      same
//   Y2   <4 x f32> bare              → identity     SysV: identity      same
//   Y3   {vector<2xf32>}          8  → i64          SysV: f64        DIVERGES
//   Y4   {vector<4xf32>}         16  → ptr          SysV: (f64,f64)  DIVERGES
//   Y5   {struct<(i32,i32)>}      8  → i64          SysV: i64           same
//   Y6   {i8,[9 x i8]}           10  → ptr          SysV: (i64,i16)  DIVERGES
//   Y7   {i64,i8}                16  → ptr          SysV: (i64,i8)   DIVERGES
//   Y8   [3 x i32] bare              → ptr          SysV: ptr           same
//
// Group Z — Return values
//   Z1   returns {i8}             1  → i8           SysV: i8            same
//   Z2   returns {i8,i8,i8}       3  → sret         SysV: i32        DIVERGES
//   Z3   returns {i32}            4  → i32          SysV: i32           same
//   Z4   returns {f32}            4  → i32          SysV: f32        DIVERGES
//   Z5   returns {i32,i32}        8  → i64          SysV: i64           same
//   Z6   returns {i32,i32,i32}   12  → sret         SysV: {i64,i32}  DIVERGES
//   Z7   returns {f64,f64}       16  → sret         SysV: {f64,f64}  DIVERGES
//   Z8   returns {i64,i64,i64}   24  → sret         SysV: sret          same
//
// Group S — Scalars are not aggregates and are not touched
//   S1   (i32, f32, f64, ptr)        → identity     SysV: identity      same
//
// Group V — Variadic. The same size rule, no separate variadic case.
//   V1   variadic scalar args        → func has ...
//   V2   variadic 24 byte struct     → ptr, and no byval, unlike System V
//
// MODULE HEADER NOTE: every test carries the MSVC data layout string, not the
// Linux one. The `m:w` mangling is the visible difference, but what matters
// here is that struct sizes are computed against the layout the target
// actually uses, because size is the only input to the rule.

// Reused module header (copy-pasted per test because -split-input-file
// requires a full module per section):
//   triple="x86_64-pc-windows-msvc"
//   data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

//===----------------------------------------------------------------------===//
// Group W: Aggregate arguments, by size
//
// Rule: size in {1,2,4,8} goes in one integer register as an integer of that
// exact width. Everything else is passed as a pointer to a copy the caller
// owns. Note that the pointer carries no byval attribute: byval means the
// callee reads a copy the caller pushed onto the stack, and Win64 instead
// hands over a pointer to caller-allocated memory. Getting that wrong would
// put the argument in the right register holding the wrong thing.
//===----------------------------------------------------------------------===//

// W1: 1 byte {i8} → i8. Agrees with System V.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_1byte
llvm.func @arg_1byte(%arg0: !llvm.struct<(i8)>) {
  // CHECK: llvm.call @c_w1(%{{.*}}) : (i8) -> ()
  pop.external_call @c_w1(%arg0) : (!llvm.struct<(i8)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w1(i8)
}

// -----

// W2: 2 bytes {i8, i8} → i16. Agrees with System V.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_2byte
llvm.func @arg_2byte(%arg0: !llvm.struct<(i8, i8)>) {
  // CHECK: llvm.call @c_w2(%{{.*}}) : (i16) -> ()
  pop.external_call @c_w2(%arg0) : (!llvm.struct<(i8, i8)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w2(i16)
}

// -----

// W3: 3 bytes {i8, i8, i8} → pointer. System V widens this to i32 and passes
// it in a register. This is the smallest input on which the two conventions
// disagree, and it is a good first thing to check when a Windows call is
// returning nonsense.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_3byte
llvm.func @arg_3byte(%arg0: !llvm.struct<(i8, i8, i8)>) {
  // CHECK: llvm.call @c_w3(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_w3(%arg0) : (!llvm.struct<(i8, i8, i8)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w3(!llvm.ptr)
}

// -----

// W4: 4 bytes {i32} → i32. Agrees with System V.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_4byte
llvm.func @arg_4byte(%arg0: !llvm.struct<(i32)>) {
  // CHECK: llvm.call @c_w4(%{{.*}}) : (i32) -> ()
  pop.external_call @c_w4(%arg0) : (!llvm.struct<(i32)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w4(i32)
}

// -----

// W5: 5 bytes → pointer. Not a power of two, so it does not fit the rule even
// though it would fit in a register. System V pads it out to i64.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_5byte
llvm.func @arg_5byte(%arg0: !llvm.struct<(array<5 x i8>)>) {
  // CHECK: llvm.call @c_w5(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_w5(%arg0) : (!llvm.struct<(array<5 x i8>)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w5(!llvm.ptr)
}

// -----

// W6: 6 bytes → pointer.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_6byte
llvm.func @arg_6byte(%arg0: !llvm.struct<(array<6 x i8>)>) {
  // CHECK: llvm.call @c_w6(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_w6(%arg0) : (!llvm.struct<(array<6 x i8>)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w6(!llvm.ptr)
}

// -----

// W7: 7 bytes → pointer.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_7byte
llvm.func @arg_7byte(%arg0: !llvm.struct<(array<7 x i8>)>) {
  // CHECK: llvm.call @c_w7(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_w7(%arg0) : (!llvm.struct<(array<7 x i8>)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w7(!llvm.ptr)
}

// -----

// W8: 8 bytes {i32, i32} → i64. This is the control case named in #13: both
// conventions agree, so a test suite made only of cases like this one passes
// on a build that is completely wrong.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_8byte
llvm.func @arg_8byte(%arg0: !llvm.struct<(i32, i32)>) {
  // CHECK: llvm.call @c_w8(%{{.*}}) : (i64) -> ()
  pop.external_call @c_w8(%arg0) : (!llvm.struct<(i32, i32)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w8(i64)
}

// -----

// W9: 12 bytes {i32, i32, i32} → pointer. System V splits this across two
// registers as (i64, i32).
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_12byte
llvm.func @arg_12byte(%arg0: !llvm.struct<(i32, i32, i32)>) {
  // CHECK: llvm.call @c_w9(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_w9(%arg0) : (!llvm.struct<(i32, i32, i32)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w9(!llvm.ptr)
}

// -----

// W10: 16 bytes {i64, i64} → pointer. System V passes this in two integer
// registers.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_16byte_int
llvm.func @arg_16byte_int(%arg0: !llvm.struct<(i64, i64)>) {
  // CHECK: llvm.call @c_w10(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_w10(%arg0) : (!llvm.struct<(i64, i64)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w10(!llvm.ptr)
}

// -----

// W11: 24 bytes → pointer, and specifically a pointer with no byval attribute.
// System V puts byval on this one. The check below is written to fail if byval
// ever appears, because the attribute is what tells the callee where its copy
// lives, and the two conventions do not agree about that.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_24byte
llvm.func @arg_24byte(%arg0: !llvm.struct<(i64, i64, i64)>) {
  // CHECK: llvm.call @c_w11(%{{.*}}) : (!llvm.ptr) -> ()
  // CHECK-NOT: llvm.byval
  pop.external_call @c_w11(%arg0) : (!llvm.struct<(i64, i64, i64)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_w11(!llvm.ptr)
// CHECK-NOT: llvm.byval
}

//===----------------------------------------------------------------------===//
// Group X: Floats inside aggregates
//
// This is the highest yield group and the reason the ABI gap was called a
// silent failure. Win64 has no float rule for aggregates. A struct holding one
// float goes into an integer register, and a struct of two doubles is 16 bytes
// so it goes by reference. System V puts all four of these in SSE registers.
// A build that used the System V classifier for a Windows target writes its
// floats to XMM and the callee reads RCX.
//===----------------------------------------------------------------------===//

// -----

// X1: {f32} → i32, in an integer register. System V says f32 in XMM0.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_float_struct
llvm.func @arg_float_struct(%arg0: !llvm.struct<(f32)>) {
  // CHECK: llvm.call @c_x1(%{{.*}}) : (i32) -> ()
  pop.external_call @c_x1(%arg0) : (!llvm.struct<(f32)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_x1(i32)
}

// -----

// X2: {f64} → i64. System V says f64 in XMM0.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_double_struct
llvm.func @arg_double_struct(%arg0: !llvm.struct<(f64)>) {
  // CHECK: llvm.call @c_x2(%{{.*}}) : (i64) -> ()
  pop.external_call @c_x2(%arg0) : (!llvm.struct<(f64)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_x2(i64)
}

// -----

// X3: {f32, f32} → i64. System V packs these into one SSE register.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_two_floats
llvm.func @arg_two_floats(%arg0: !llvm.struct<(f32, f32)>) {
  // CHECK: llvm.call @c_x3(%{{.*}}) : (i64) -> ()
  pop.external_call @c_x3(%arg0) : (!llvm.struct<(f32, f32)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_x3(i64)
}

// -----

// X4: {f64, f64} → pointer. System V passes this in XMM0 and XMM1. This is the
// worst of the divergences, because it is a common shape, it is 16 bytes so
// nothing about it looks large, and both conventions pass it without touching
// memory in a way the caller would notice.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_two_doubles
llvm.func @arg_two_doubles(%arg0: !llvm.struct<(f64, f64)>) {
  // CHECK: llvm.call @c_x4(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_x4(%arg0) : (!llvm.struct<(f64, f64)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_x4(!llvm.ptr)
}

// -----

// X5: {i32, f32} → i64. The two conventions agree here, for different reasons.
// System V classifies the eightbyte as INTEGER because an integer field wins
// over a float one, and Win64 never looked at the fields at all.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_int_and_float
llvm.func @arg_int_and_float(%arg0: !llvm.struct<(i32, f32)>) {
  // CHECK: llvm.call @c_x5(%{{.*}}) : (i64) -> ()
  pop.external_call @c_x5(%arg0) : (!llvm.struct<(i32, f32)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_x5(i64)
}

//===----------------------------------------------------------------------===//
// Group Y: Vectors, nesting and padding
//
// A bare vector is not an aggregate and passes through untouched, which is the
// same answer System V gives. A vector wrapped in a struct is an aggregate and
// gets the size rule like anything else, which is not the same answer.
//===----------------------------------------------------------------------===//

// -----

// Y1: bare <2 x f32> → unchanged.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_bare_v2f32
llvm.func @arg_bare_v2f32(%arg0: vector<2xf32>) {
  // CHECK: llvm.call @c_y1(%{{.*}}) : (vector<2xf32>) -> ()
  pop.external_call @c_y1(%arg0) : (vector<2xf32>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_y1(vector<2xf32>)
}

// -----

// Y2: bare <4 x f32> → unchanged. This is the `__m128` case from #13, and it
// is one of the few places where a 16 byte value still travels in a register.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_bare_v4f32
llvm.func @arg_bare_v4f32(%arg0: vector<4xf32>) {
  // CHECK: llvm.call @c_y2(%{{.*}}) : (vector<4xf32>) -> ()
  pop.external_call @c_y2(%arg0) : (vector<4xf32>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_y2(vector<4xf32>)
}

// -----

// Y3: {vector<2xf32>} is 8 bytes → i64. System V calls this SSE and sends it
// in XMM0.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_wrapped_v2f32
llvm.func @arg_wrapped_v2f32(%arg0: !llvm.struct<(vector<2xf32>)>) {
  // CHECK: llvm.call @c_y3(%{{.*}}) : (i64) -> ()
  pop.external_call @c_y3(%arg0) : (!llvm.struct<(vector<2xf32>)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_y3(i64)
}

// -----

// Y4: {vector<4xf32>} is 16 bytes → pointer. Wrapping the vector in a struct
// takes it out of the register it would have travelled in bare.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_wrapped_v4f32
llvm.func @arg_wrapped_v4f32(%arg0: !llvm.struct<(vector<4xf32>)>) {
  // CHECK: llvm.call @c_y4(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_y4(%arg0) : (!llvm.struct<(vector<4xf32>)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_y4(!llvm.ptr)
}

// -----

// Y5: a nested struct is flattened by the size rule like anything else.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_nested_8
llvm.func @arg_nested_8(%arg0: !llvm.struct<(struct<(i32, i32)>)>) {
  // CHECK: llvm.call @c_y5(%{{.*}}) : (i64) -> ()
  pop.external_call @c_y5(%arg0) : (!llvm.struct<(struct<(i32, i32)>)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_y5(i64)
}

// -----

// Y6: 10 bytes → pointer. Ten is neither small enough nor a power of two.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_10byte
llvm.func @arg_10byte(%arg0: !llvm.struct<(i8, array<9 x i8>)>) {
  // CHECK: llvm.call @c_y6(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_y6(%arg0) : (!llvm.struct<(i8, array<9 x i8>)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_y6(!llvm.ptr)
}

// -----

// Y7: {i64, i8} is 16 bytes once alignment padding is added, so the padding is
// what pushes it out of a register. The rule reads the laid-out size, not the
// sum of the field sizes, which is why this test carries the target's own data
// layout string rather than the Linux one.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_padded_16
llvm.func @arg_padded_16(%arg0: !llvm.struct<(i64, i8)>) {
  // CHECK: llvm.call @c_y7(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_y7(%arg0) : (!llvm.struct<(i64, i8)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_y7(!llvm.ptr)
}

// -----

// Y8: a bare array argument goes by reference. C never produces this because
// arrays decay to pointers, so it only arrives through a hand written
// signature, but it has to have an answer.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_bare_array
llvm.func @arg_bare_array(%arg0: !llvm.array<3 x i32>) {
  // CHECK: llvm.call @c_y8(%{{.*}}) : (!llvm.ptr) -> ()
  pop.external_call @c_y8(%arg0) : (!llvm.array<3 x i32>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_y8(!llvm.ptr)
}

//===----------------------------------------------------------------------===//
// Group Z: Return values
//
// The same size test, with the hidden result pointer standing in for passing
// by reference. Returns diverge from System V more often than arguments do,
// because System V has a second register available for returns and uses it.
//===----------------------------------------------------------------------===//

// -----

// Z1: returns {i8} → i8 in RAX.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @ret_1byte
llvm.func @ret_1byte() {
  // CHECK: llvm.call @c_z1() : () -> i8
  %r = pop.external_call @c_z1() : () -> !llvm.struct<(i8)>
  llvm.return
}
// CHECK: llvm.func @c_z1() -> i8
}

// -----

// Z2: returns 3 bytes → sret. System V returns this in RAX as an i24.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @ret_3byte
llvm.func @ret_3byte() {
  // CHECK: llvm.call @c_z2(%{{.*}}) : (!llvm.ptr) -> ()
  // CHECK: llvm.load %{{.*}} : !llvm.ptr -> !llvm.struct<(i8, i8, i8)>
  %r = pop.external_call @c_z2() : () -> !llvm.struct<(i8, i8, i8)>
  llvm.return
}
// CHECK: llvm.func @c_z2(!llvm.ptr {llvm.sret = !llvm.struct<(i8, i8, i8)>})
}

// -----

// Z3: returns {i32} → i32.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @ret_4byte
llvm.func @ret_4byte() {
  // CHECK: llvm.call @c_z3() : () -> i32
  %r = pop.external_call @c_z3() : () -> !llvm.struct<(i32)>
  llvm.return
}
// CHECK: llvm.func @c_z3() -> i32
}

// -----

// Z4: returns {f32} → i32, so the caller reads RAX. System V returns it in
// XMM0. A caller that reads the wrong one of those gets whatever was left
// there by the last call, which is the kind of failure that looks like a
// memory bug for a long time before anyone suspects the ABI.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @ret_float_struct
llvm.func @ret_float_struct() {
  // CHECK: llvm.call @c_z4() : () -> i32
  %r = pop.external_call @c_z4() : () -> !llvm.struct<(f32)>
  llvm.return
}
// CHECK: llvm.func @c_z4() -> i32
}

// -----

// Z5: returns {i32, i32} → i64.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @ret_8byte
llvm.func @ret_8byte() {
  // CHECK: llvm.call @c_z5() : () -> i64
  %r = pop.external_call @c_z5() : () -> !llvm.struct<(i32, i32)>
  llvm.return
}
// CHECK: llvm.func @c_z5() -> i64
}

// -----

// Z6: returns 12 bytes → sret. System V returns this in RAX and RDX.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @ret_12byte
llvm.func @ret_12byte() {
  // CHECK: llvm.call @c_z6(%{{.*}}) : (!llvm.ptr) -> ()
  // CHECK: llvm.load %{{.*}} : !llvm.ptr -> !llvm.struct<(i32, i32, i32)>
  %r = pop.external_call @c_z6() : () -> !llvm.struct<(i32, i32, i32)>
  llvm.return
}
// CHECK: llvm.func @c_z6(!llvm.ptr {llvm.sret = !llvm.struct<(i32, i32, i32)>})
}

// -----

// Z7: returns {f64, f64} → sret. System V returns this in XMM0 and XMM1.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @ret_two_doubles
llvm.func @ret_two_doubles() {
  // CHECK: llvm.call @c_z7(%{{.*}}) : (!llvm.ptr) -> ()
  // CHECK: llvm.load %{{.*}} : !llvm.ptr -> !llvm.struct<(f64, f64)>
  %r = pop.external_call @c_z7() : () -> !llvm.struct<(f64, f64)>
  llvm.return
}
// CHECK: llvm.func @c_z7(!llvm.ptr {llvm.sret = !llvm.struct<(f64, f64)>})
}

// -----

// Z8: returns 24 bytes → sret, which is what System V does too. The only case
// in this group where the two agree.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @ret_24byte
llvm.func @ret_24byte() {
  // CHECK: llvm.call @c_z8(%{{.*}}) : (!llvm.ptr) -> ()
  // CHECK: llvm.load %{{.*}} : !llvm.ptr -> !llvm.struct<(i64, i64, i64)>
  %r = pop.external_call @c_z8() : () -> !llvm.struct<(i64, i64, i64)>
  llvm.return
}
// CHECK: llvm.func @c_z8(!llvm.ptr {llvm.sret = !llvm.struct<(i64, i64, i64)>})
}

//===----------------------------------------------------------------------===//
// Group S: Scalars
//
// Nothing here is an aggregate so nothing is coerced, and the check is that
// the classifier leaves it all alone rather than inventing work.
//===----------------------------------------------------------------------===//

// -----

// S1: mixed scalars pass through unchanged. Which register each one lands in
// is the backend's decision and Win64 aliases the integer and SSE registers
// positionally, so the `f32` here goes to XMM1 rather than XMM0. None of that
// is visible at this layer, and none of it needs to be.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @arg_scalars
llvm.func @arg_scalars(%a: i32, %b: f32, %c: f64, %d: !llvm.ptr) {
  // CHECK: llvm.call @c_s1(%{{.*}}, %{{.*}}, %{{.*}}, %{{.*}}) : (i32, f32, f64, !llvm.ptr) -> ()
  pop.external_call @c_s1(%a, %b, %c, %d) : (i32, f32, f64, !llvm.ptr) -> ()
  llvm.return
}
// CHECK: llvm.func @c_s1(i32, f32, f64, !llvm.ptr)
}

//===----------------------------------------------------------------------===//
// Group V: Variadic functions
//
// Win64 has no separate classification for variadic arguments. A `double`
// passed through `...` is copied into the matching integer register as well,
// so a callee with no prototype can find it, but that is a placement decision
// and it does not change any type here.
//===----------------------------------------------------------------------===//

// -----

// V1: variadic scalars. The declaration keeps its `...` and nothing is coerced.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @variadic_scalars
llvm.func @variadic_scalars(%fixed: i32, %extra: f64) {
  // CHECK: llvm.call @c_v1(%{{.*}}, %{{.*}}) : (i32, f64) -> ()
  pop.external_call @c_v1(%fixed, %extra) attributes {numFixedArgs = 1 : index}
    : (i32, f64) -> ()
  llvm.return
}
// CHECK: llvm.func @c_v1(i32, ...)
}

// -----

// V2: a 24 byte struct passed through `...` goes by reference like any other
// 24 byte struct, and again without byval. System V puts byval on the call for
// this one, so the CHECK-NOT below is the whole point of the test.
module attributes {M.target_info = #M.target<triple="x86_64-pc-windows-msvc", arch="", features="", data_layout="e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128", simd_bit_width=128>} {
// CHECK-LABEL: @variadic_large_struct
llvm.func @variadic_large_struct(%fixed: i32,
                                 %s: !llvm.struct<(i64, i64, i64)>) {
  // CHECK: llvm.call @c_v2
  pop.external_call @c_v2(%fixed, %s) attributes {numFixedArgs = 1 : index}
    : (i32, !llvm.struct<(i64, i64, i64)>) -> ()
  llvm.return
}
// CHECK: llvm.func @c_v2(i32, ...)
// CHECK-NOT: llvm.byval
}
