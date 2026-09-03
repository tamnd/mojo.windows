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
// The recording buffer, and the scalar probes. Struct probes are in
// probe_structs.c and write into the same buffer.
//
// This is the ground truth half of the ABI conformance suite. Every function
// here is compiled by the platform C compiler, so what it does with its
// arguments is by definition what the platform ABI says. The Mojo half calls
// these and compares what arrived against what it sent. A mismatch is a
// lowering bug in the Mojo compiler, pinned to one signature.
//
// The probes record their arguments into a buffer rather than echoing them back
// through a return value. Echoing is the obvious design and it is worse in two
// ways. It only reports the first thing that went wrong, because a wrong return
// value tells you nothing about the fifth argument. And it puts the return path
// and the argument path in the same test, so a failure does not say which of the
// two is broken. Recording separates them: the argument path is checked through
// the buffer, the return path is checked by its own family of probes that take
// one argument and return one value.
//
// Nothing here is thread safe and nothing here needs to be. The suite is one
// call at a time on one thread, and adding a lock would put a call of its own
// between the probe and the thing being measured.

#include "Mojo/test/abi-conformance/probe.h"

#include <stdint.h>

enum { ABI_PROBE_MAX_SLOTS = 32 };

static int64_t g_int_slots[ABI_PROBE_MAX_SLOTS];
static double g_float_slots[ABI_PROBE_MAX_SLOTS];
static int32_t g_count;

void abi_probe_record_int(int64_t value) {
  if (g_count < ABI_PROBE_MAX_SLOTS) {
    g_int_slots[g_count] = value;
    g_float_slots[g_count] = 0.0;
    g_count += 1;
  }
}

void abi_probe_record_float(double value) {
  if (g_count < ABI_PROBE_MAX_SLOTS) {
    g_int_slots[g_count] = 0;
    g_float_slots[g_count] = value;
    g_count += 1;
  }
}

void abi_probe_reset(void) { g_count = 0; }

int32_t abi_probe_count(void) { return g_count; }

// Out of range reads return a value no probe ever passes, so a test that gets
// the slot count wrong fails loudly instead of reading a stale slot.
int64_t abi_probe_int(int32_t index) {
  if (index < 0 || index >= g_count) {
    return INT64_MIN;
  }
  return g_int_slots[index];
}

double abi_probe_float(int32_t index) {
  if (index < 0 || index >= g_count) {
    return -1.0e308;
  }
  return g_float_slots[index];
}

//===----------------------------------------------------------------------===//
// Six argument probes
//===----------------------------------------------------------------------===//
//
// Six is the interesting width. System V passes six integers in registers and
// spills the seventh, Win64 passes four of anything and spills the fifth, so a
// six argument call crosses the Win64 boundary and stays inside the System V
// one. The macro expands to a function that records its arguments in order and
// nothing else, which is the whole job.

#define PROBE6(name, t1, t2, t3, t4, t5, t6, r1, r2, r3, r4, r5, r6) \
  void name(t1 a1, t2 a2, t3 a3, t4 a4, t5 a5, t6 a6) {              \
    r1(a1);                                                          \
    r2(a2);                                                          \
    r3(a3);                                                          \
    r4(a4);                                                          \
    r5(a5);                                                          \
    r6(a6);                                                          \
  }

#define I abi_probe_record_int
#define F abi_probe_record_float

// Integer scalars at each width. Narrow types are the ones worth passing
// negative values through, because neither ABI says anything about the upper
// bits of the register a narrow argument arrives in, and a caller that assumes
// the callee will ignore them works right up until the callee does not.
PROBE6(abi_int8_x6, int8_t, int8_t, int8_t, int8_t, int8_t, int8_t, I, I, I, I,
       I, I)
PROBE6(abi_int16_x6, int16_t, int16_t, int16_t, int16_t, int16_t, int16_t, I, I,
       I, I, I, I)
PROBE6(abi_int32_x6, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, I, I,
       I, I, I, I)
PROBE6(abi_int64_x6, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, I, I,
       I, I, I, I)

// Floating point scalars at each width.
PROBE6(abi_float32_x6, float, float, float, float, float, float, F, F, F, F, F,
       F)
PROBE6(abi_float64_x6, double, double, double, double, double, double, F, F, F,
       F, F, F)

// One double among integers, at each of the six positions, and then one integer
// among doubles the same way. This is the highest yield family in the suite.
// Win64 numbers the two register files together, so a double in position three
// lands in XMM2 and leaves RDX empty. System V numbers them separately, so the
// same double lands in XMM0 and the integers stay packed into RDI, RSI, RDX.
// Get that wrong and every argument after the first float is read from the
// wrong register, which is a large and completely silent error.
PROBE6(abi_float64_at1, double, int64_t, int64_t, int64_t, int64_t, int64_t, F,
       I, I, I, I, I)
PROBE6(abi_float64_at2, int64_t, double, int64_t, int64_t, int64_t, int64_t, I,
       F, I, I, I, I)
PROBE6(abi_float64_at3, int64_t, int64_t, double, int64_t, int64_t, int64_t, I,
       I, F, I, I, I)
PROBE6(abi_float64_at4, int64_t, int64_t, int64_t, double, int64_t, int64_t, I,
       I, I, F, I, I)
PROBE6(abi_float64_at5, int64_t, int64_t, int64_t, int64_t, double, int64_t, I,
       I, I, I, F, I)
PROBE6(abi_float64_at6, int64_t, int64_t, int64_t, int64_t, int64_t, double, I,
       I, I, I, I, F)

PROBE6(abi_int64_at1, int64_t, double, double, double, double, double, I, F, F,
       F, F, F)
PROBE6(abi_int64_at2, double, int64_t, double, double, double, double, F, I, F,
       F, F, F)
PROBE6(abi_int64_at3, double, double, int64_t, double, double, double, F, F, I,
       F, F, F)
PROBE6(abi_int64_at4, double, double, double, int64_t, double, double, F, F, F,
       I, F, F)
PROBE6(abi_int64_at5, double, double, double, double, int64_t, double, F, F, F,
       F, I, F)
PROBE6(abi_int64_at6, double, double, double, double, double, int64_t, F, F, F,
       F, F, I)

// A float rather than a double at each position, against 32 bit integers. Same
// register allocation question, but the halves of the registers that go unused
// are different, which catches a lowering that gets the register right and the
// width wrong.
PROBE6(abi_float32_at1, float, int32_t, int32_t, int32_t, int32_t, int32_t, F,
       I, I, I, I, I)
PROBE6(abi_float32_at2, int32_t, float, int32_t, int32_t, int32_t, int32_t, I,
       F, I, I, I, I)
PROBE6(abi_float32_at3, int32_t, int32_t, float, int32_t, int32_t, int32_t, I, I,
       F, I, I, I)
PROBE6(abi_float32_at4, int32_t, int32_t, int32_t, float, int32_t, int32_t, I, I,
       I, F, I, I)
PROBE6(abi_float32_at5, int32_t, int32_t, int32_t, int32_t, float, int32_t, I, I,
       I, I, F, I)
PROBE6(abi_float32_at6, int32_t, int32_t, int32_t, int32_t, int32_t, float, I, I,
       I, I, I, F)

// The alternating shapes, which are what real code looks like.
PROBE6(abi_mixed_ifif_x6, int32_t, double, int32_t, double, int32_t, double, I,
       F, I, F, I, F)
PROBE6(abi_mixed_fifi_x6, double, int32_t, double, int32_t, double, int32_t, F,
       I, F, I, F, I)

#undef PROBE6
#undef I
#undef F

//===----------------------------------------------------------------------===//
// Spilling probes
//===----------------------------------------------------------------------===//
//
// Nine arguments is past the register file under both ABIs, so the tail of each
// of these arrives on the stack. Win64 spills from the fifth, System V from the
// seventh for integers and the ninth for floats, which means the same call has
// a different split between registers and stack on the two platforms and the
// only way to be sure the stack half is right is to run it.

void abi_int64_x9(int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5,
                  int64_t a6, int64_t a7, int64_t a8, int64_t a9) {
  abi_probe_record_int(a1);
  abi_probe_record_int(a2);
  abi_probe_record_int(a3);
  abi_probe_record_int(a4);
  abi_probe_record_int(a5);
  abi_probe_record_int(a6);
  abi_probe_record_int(a7);
  abi_probe_record_int(a8);
  abi_probe_record_int(a9);
}

void abi_float64_x9(double a1, double a2, double a3, double a4, double a5,
                    double a6, double a7, double a8, double a9) {
  abi_probe_record_float(a1);
  abi_probe_record_float(a2);
  abi_probe_record_float(a3);
  abi_probe_record_float(a4);
  abi_probe_record_float(a5);
  abi_probe_record_float(a6);
  abi_probe_record_float(a7);
  abi_probe_record_float(a8);
  abi_probe_record_float(a9);
}

// Mixed and spilled at once, which is where the two ABIs disagree the most. On
// Win64 the fifth argument onwards is on the stack whatever its type. On System
// V the five integers all fit in registers and so do the four doubles, and
// nothing spills at all.
void abi_mixed_x9(int32_t a1, double a2, int64_t a3, float a4, int32_t a5,
                  double a6, int64_t a7, float a8, int32_t a9) {
  abi_probe_record_int(a1);
  abi_probe_record_float(a2);
  abi_probe_record_int(a3);
  abi_probe_record_float(a4);
  abi_probe_record_int(a5);
  abi_probe_record_float(a6);
  abi_probe_record_int(a7);
  abi_probe_record_float(a8);
  abi_probe_record_int(a9);
}

//===----------------------------------------------------------------------===//
// Return probes
//===----------------------------------------------------------------------===//
//
// One argument in and one value out, so a failure is unambiguously the return
// path. Each one changes the value it was given rather than returning a
// constant, because a constant return can be right by accident when the
// argument never arrived.

int8_t abi_ret_int8(int8_t v) { return (int8_t)(v + 1); }
int16_t abi_ret_int16(int16_t v) { return (int16_t)(v + 1); }
int32_t abi_ret_int32(int32_t v) { return v + 1; }
int64_t abi_ret_int64(int64_t v) { return v + 1; }
float abi_ret_float32(float v) { return v + 1.0f; }
double abi_ret_float64(double v) { return v + 1.0; }

// A return from a call that has already used up the register file. The return
// register is not one of the argument registers under either ABI, but the
// lowering that decides where the return goes is the same code that decides
// where the arguments go, and this is the shape that catches it borrowing the
// wrong state.
int64_t abi_ret_int64_after_x6(int64_t a1, int64_t a2, int64_t a3, int64_t a4,
                               int64_t a5, int64_t a6) {
  return a1 + a2 + a3 + a4 + a5 + a6;
}

double abi_ret_float64_after_x6(double a1, double a2, double a3, double a4,
                                double a5, double a6) {
  return a1 + a2 + a3 + a4 + a5 + a6;
}

// The mixed version of the same, where the argument that decides the answer is
// the one furthest from the return register.
double abi_ret_float64_after_mixed(int32_t a1, double a2, int64_t a3, float a4,
                                   int32_t a5, double a6) {
  return (double)a1 + a2 + (double)a3 + (double)a4 + (double)a5 + a6;
}
