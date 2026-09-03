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
// Probes for the C types whose width is not the same on both platforms, and for
// bool, whose width is the same but whose representation is easy to get wrong.
//
// Everything else in this suite is about where an argument lands. This file is
// about how wide it is before it gets there. The two questions are independent
// and this is the only file where Linux and Windows are expected to give
// different answers, so the tests ask C what the width is rather than hardcoding
// a number per platform.
//
// The interesting type is long. Linux and macOS are LP64 and give it 64 bits.
// Windows is LLP64 and leaves it at 32, putting the extra width on long long and
// on pointers instead. A caller that assumes LP64 on Windows sends twice the
// bytes the callee reads, and on x86-64 that is invisible for the values this
// file passes, because a slot is eight bytes wide whatever is in it and the
// callee reads the low end. So the size reporting functions below are not a
// preamble to the real test. For long they are the test, and the probes that
// pass values are there to say what else the width did not break.

#include "Mojo/test/abi-conformance/probe.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define I abi_probe_record_int

// The widths, straight from the compiler that is building this file. The Mojo
// side compares its own size_of against these rather than against a table,
// because a table is one more thing that can be wrong and it would be wrong in
// the same direction as the bug it is meant to catch.
#define SIZE_OF(name, type)       \
  int32_t name(void) {            \
    return (int32_t)sizeof(type); \
  }

SIZE_OF(abi_size_c_char, char)
SIZE_OF(abi_size_c_short, short)
SIZE_OF(abi_size_c_int, int)
SIZE_OF(abi_size_c_long, long)
SIZE_OF(abi_size_c_long_long, long long)
SIZE_OF(abi_size_c_size_t, size_t)
SIZE_OF(abi_size_pointer, void *)
SIZE_OF(abi_size_bool, _Bool)

#undef SIZE_OF

// Whether plain char is signed is a third thing the data model leaves open, and
// it is not tied to the pointer width. It happens to be signed on x86-64 Windows
// and Linux both, and it is unsigned on ARM Linux, which matters for the arm64
// port later.
int32_t abi_char_is_signed(void) { return (char)-1 < 0 ? 1 : 0; }

// Six longs, all of them in registers under both conventions. The plain case,
// here so that the ones below have something to differ from.
void abi_long_x6(long a1, long a2, long a3, long a4, long a5, long a6) {
  I(a1);
  I(a2);
  I(a3);
  I(a4);
  I(a5);
  I(a6);
}

void abi_ulong_x6(unsigned long a1, unsigned long a2, unsigned long a3,
                  unsigned long a4, unsigned long a5, unsigned long a6) {
  I((int64_t)a1);
  I((int64_t)a2);
  I((int64_t)a3);
  I((int64_t)a4);
  I((int64_t)a5);
  I((int64_t)a6);
}

void abi_long_long_x6(long long a1, long long a2, long long a3, long long a4,
                      long long a5, long long a6) {
  I(a1);
  I(a2);
  I(a3);
  I(a4);
  I(a5);
  I(a6);
}

// long next to types that are the same width everywhere. This asks whether a
// narrow argument between wide ones still takes a slot of its own, which is a
// placement question rather than a width one.
void abi_long_mixed(long a1, int64_t a2, long a3, int32_t a4, long a5,
                    int64_t a6) {
  I(a1);
  I(a2);
  I(a3);
  I(a4);
  I(a5);
  I(a6);
}

// Nine, so the last three go past the register file. A stack slot is 8 bytes
// wide whatever the argument is, so this asks whether a 32 bit long still takes
// a whole slot on Windows, which it does.
void abi_long_x9(long a1, long a2, long a3, long a4, long a5, long a6, long a7,
                 long a8, long a9) {
  I(a1);
  I(a2);
  I(a3);
  I(a4);
  I(a5);
  I(a6);
  I(a7);
  I(a8);
  I(a9);
}

long abi_ret_long(long value) { return value + 1; }

unsigned long abi_ret_ulong(unsigned long value) { return value + 1u; }

long long abi_ret_long_long(long long value) { return value + 1; }

// Negative values on purpose. A narrow signed argument arrives in a register
// that is wider than it is, and the bits above the value are the caller's
// business to get right. Positive values look the same either way, so a caller
// that zero extends where it should sign extend only shows up here.
void abi_long_negative(long a1, long a2, long a3) {
  I(a1);
  I(a2);
  I(a3);
}

void abi_bool_x6(_Bool a1, _Bool a2, _Bool a3, _Bool a4, _Bool a5, _Bool a6) {
  I(a1 ? 1 : 0);
  I(a2 ? 1 : 0);
  I(a3 ? 1 : 0);
  I(a4 ? 1 : 0);
  I(a5 ? 1 : 0);
  I(a6 ? 1 : 0);
}

void abi_bool_mixed(_Bool a1, int64_t a2, _Bool a3, double a4, _Bool a5,
                    int32_t a6) {
  I(a1 ? 1 : 0);
  I(a2);
  I(a3 ? 1 : 0);
  abi_probe_record_float(a4);
  I(a5 ? 1 : 0);
  I(a6);
}

// Bools past the register file, where the question is whether a one byte
// argument still consumes a full eight byte stack slot. It does, and a caller
// that packs them would put every argument after them in the wrong place.
void abi_bool_spill(int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5,
                    _Bool a6, _Bool a7, _Bool a8) {
  I(a1);
  I(a2);
  I(a3);
  I(a4);
  I(a5);
  I(a6 ? 1 : 0);
  I(a7 ? 1 : 0);
  I(a8 ? 1 : 0);
}

_Bool abi_ret_bool(_Bool value) { return !value; }

// The raw byte the bool arrived as, before anything decides whether it counts as
// true. The ABI says a bool argument is 0 or 1 and says nothing about the bits
// above it, so a caller that passes 0xff for true is passing something the
// callee is allowed to reject.
//
// This check is worth less than the others and it is worth saying why. The C
// compiler may normalise the value on the way in, and if it does then a bad
// caller passes here anyway. A failure means there is definitely a bug. A pass
// means there is probably not one.
int32_t abi_bool_raw_byte(_Bool value) {
  unsigned char raw;
  memcpy(&raw, &value, 1);
  return (int32_t)raw;
}

#undef I
