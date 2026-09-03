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
// Vector probes. Four floats in sixteen bytes, which is __m128 under another
// name, and the pair of doubles that shares its size.
//
// This is the sharpest disagreement left in the suite. System V has a class of
// its own for a sixteen byte vector and passes it in an SSE register. Win64 has
// no such class and no register wide enough by its own accounting, so a vector
// argument is copied to memory and passed as a pointer, and it comes back
// through a hidden pointer the caller supplies. Same source, same type, and one
// convention puts it in a register while the other never does.
//
// A lowering that gets the struct rules right can still get this wrong, because
// the struct rules are about size and these are not: a sixteen byte struct of
// two doubles and a sixteen byte vector of two doubles are the same size and
// System V treats them differently. That is why they get their own file.
//
// The vectors are spelled with vector_size rather than by including a header for
// __m128. The attribute is what the header is built out of, it works the same on
// both targets, and it keeps a file that is about calling conventions from
// depending on which intrinsics header the sysroot happens to ship.

#include "Mojo/test/abi-conformance/probe.h"

#include <stdint.h>

#define F abi_probe_record_float
#define I abi_probe_record_int

typedef float v4f __attribute__((vector_size(16)));
typedef double v2d __attribute__((vector_size(16)));
typedef int32_t v4i __attribute__((vector_size(16)));

int32_t abi_size_v4f(void) { return (int32_t)sizeof(v4f); }
int32_t abi_size_v2d(void) { return (int32_t)sizeof(v2d); }
int32_t abi_size_v4i(void) { return (int32_t)sizeof(v4i); }

void abi_v4f(v4f v) {
  F(v[0]);
  F(v[1]);
  F(v[2]);
  F(v[3]);
}

void abi_v2d(v2d v) {
  F(v[0]);
  F(v[1]);
}

void abi_v4i(v4i v) {
  I(v[0]);
  I(v[1]);
  I(v[2]);
  I(v[3]);
}

// Two of them, which is two SSE registers on Linux and two pointers on Windows,
// and the second one is where a lowering that handled the first by accident
// stops working.
void abi_v4f_x2(v4f a, v4f b) {
  F(a[0]);
  F(a[3]);
  F(b[0]);
  F(b[3]);
}

// A vector with scalars after it. On Windows the vector took a register slot to
// hold its address, so the scalars are one slot further along than the register
// files alone would suggest, and they are what shows if the vector was passed
// some other way.
void abi_v4f_then(v4f v, double a, int64_t b) {
  F(v[0]);
  F(v[3]);
  F(a);
  I(b);
}

// The same the other way round, so the vector is the one that has to land in the
// right place after the scalars have taken theirs.
void abi_v4f_after(int64_t a, double b, v4f v) {
  I(a);
  F(b);
  F(v[0]);
  F(v[3]);
}

// Five of them, which is past every SSE register System V hands out and past
// every register slot Win64 has, so the last ones are on the stack under both.
void abi_v4f_x5(v4f a, v4f b, v4f c, v4f d, v4f e) {
  F(a[0]);
  F(b[0]);
  F(c[0]);
  F(d[0]);
  F(e[0]);
}

// Adds one to each lane, so a return that comes back unchanged is a failure
// rather than a coincidence.
v4f abi_ret_v4f(v4f v) {
  v4f result = {v[0] + 1.0f, v[1] + 1.0f, v[2] + 1.0f, v[3] + 1.0f};
  return result;
}

v2d abi_ret_v2d(v2d v) {
  v2d result = {v[0] + 1.0, v[1] + 1.0};
  return result;
}

// A return from a call that has already spent its register slots, which is the
// case where the hidden pointer and the arguments compete for the same places.
v4f abi_ret_v4f_after(int64_t a, int64_t b, int64_t c, v4f v) {
  I(a);
  I(b);
  I(c);
  v4f result = {v[0] + 1.0f, v[1] + 1.0f, v[2] + 1.0f, v[3] + 1.0f};
  return result;
}

#undef F
#undef I
