//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//
//
// Frame probes. Everything else in this suite asks where an argument went.
// These ask about the stack the call was made on, which is the part of the
// convention the caller has to get right before any argument is placed.
//
// Two rules, and Windows is the demanding one on both.
//
// Shadow space. A Win64 caller reserves thirty two bytes above the return
// address, whether or not the call has four arguments and whether or not the
// callee wants them. They are the callee's, to spill its four register
// arguments into if it needs to, and a caller that skips the reservation has
// handed the callee thirty two bytes of its own live frame to write over.
// System V reserves nothing.
//
// Stack alignment. Both conventions want RSP to be a multiple of sixteen at
// the call instruction, so that the callee's sixteen byte locals really are
// aligned. Nothing on the way in realigns anything: the callee is compiled
// assuming the caller kept its end of it. The reason Windows is harder is that
// the shadow space and the stack argument area have to be sized together, and
// a caller that adds one and forgets to round is misaligned by exactly eight.
//
// The red zone is the third rule in this area and there is no probe for it
// here. System V lets a leaf function use the hundred and twenty eight bytes
// below RSP without reserving them, and Windows does not. A Windows caller
// that used one anyway would be correct until an interrupt or an exception
// landed on it, which is not something a test can arrange, so the only thing
// this file can say about it is that it is not covered.

#include "Mojo/test/abi-conformance/probe.h"

#include <stdint.h>

#define I abi_probe_record_int

// Opaque on purpose. The compiler cannot see that this does nothing, so it has
// to assume the call clobbers every volatile register, which is what forces the
// probes below to put their arguments somewhere that survives.
static int64_t g_sink;

__attribute__((noinline)) void abi_frame_sink(int64_t v) { g_sink += v; }

// Four register arguments, used again after a nested call. On Win64 there is
// nowhere for the callee to keep them across that call except the four home
// slots the caller reserved, so this is the shape that uses the shadow space
// for the thing it exists for.
//
// Worth being honest about what this can see. If the caller reserved nothing,
// the callee spills into whatever the caller had there, and the values still
// come back correct because the callee wrote them and the callee read them.
// What was destroyed belongs to the caller and this probe cannot see it. The
// stack argument version below is the one that catches it.
void abi_shadow_home(int64_t a, int64_t b, int64_t c, int64_t d) {
  abi_frame_sink(a + b + c + d);
  I(a);
  I(b);
  I(c);
  I(d);
}

// The same, with two more arguments on the stack. This is the one that bites.
// A correct caller puts the fifth and sixth arguments immediately above the
// thirty two bytes it reserved. A caller that reserved nothing puts them where
// the shadow space was supposed to be, which is exactly where the callee spills
// its register arguments, so the callee overwrites its own fifth and sixth
// arguments before it reads them.
void abi_shadow_stack(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e,
                      int64_t f) {
  abi_frame_sink(a + b + c + d);
  I(a);
  I(b);
  I(c);
  I(d);
  I(e);
  I(f);
}

// Floating point arguments have home slots too, and they are the same four
// slots, because Win64 numbers the two register files together. A caller that
// sized the reservation by counting integer arguments gets this one wrong.
void abi_shadow_mixed(int64_t a, double b, int64_t c, double d, int64_t e,
                      double f) {
  abi_frame_sink(a + c + e);
  I(a);
  abi_probe_record_float(b);
  I(c);
  abi_probe_record_float(d);
  I(e);
  abi_probe_record_float(f);
}

// ===--------------------------------------------------------------------=== //
// Alignment
// ===--------------------------------------------------------------------=== //
//
// How far this frame is from sixteen byte alignment, which is zero when the
// caller did its job. Asking for the alignment of a local rather than reading
// RSP directly, because a local is what the rule exists to make aligned and
// because it stays portable. The C compiler aligned this to sixteen relative to
// the stack pointer it was handed, so if the answer is not zero then the stack
// pointer it was handed was not aligned either.

int32_t abi_frame_alignment(void) {
  _Alignas(16) char local[16];
  return (int32_t)((uintptr_t)local & 15);
}

// The same question from a call with one stack argument. The outgoing frame is
// the shadow space plus the stack arguments plus whatever padding keeps the
// total a multiple of sixteen, and an odd number of stack arguments is where
// the padding is needed, so a caller that adds the pieces without rounding is
// off by eight here and correct in the probe above.
int32_t abi_frame_alignment_odd(int64_t a, int64_t b, int64_t c, int64_t d,
                                int64_t e) {
  _Alignas(16) char local[16];
  abi_frame_sink(a + b + c + d + e);
  return (int32_t)((uintptr_t)local & 15);
}

// And with two, which is the even case and should be aligned by different
// arithmetic. Having both means a caller that is right by accident in one of
// them is still caught.
int32_t abi_frame_alignment_even(int64_t a, int64_t b, int64_t c, int64_t d,
                                 int64_t e, int64_t f) {
  _Alignas(16) char local[16];
  abi_frame_sink(a + b + c + d + e + f);
  return (int32_t)((uintptr_t)local & 15);
}

// Nine arguments, so five of them are on the stack, which is the odd case again
// at a size where a caller that reserved a fixed amount rather than a computed
// one has run out.
int32_t abi_frame_alignment_deep(int64_t a, int64_t b, int64_t c, int64_t d,
                                 int64_t e, int64_t f, int64_t g, int64_t h,
                                 int64_t i) {
  _Alignas(16) char local[16];
  abi_frame_sink(a + b + c + d + e + f + g + h + i);
  return (int32_t)((uintptr_t)local & 15);
}

#undef I
