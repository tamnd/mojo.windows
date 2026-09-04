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
// Replacements for C runtime maths that Windows gets wrong.
//
// A machine without the FMA instructions cannot do a fused multiply add in
// hardware, so LLVM lowers llvm.fma to a call and the C runtime answers it. The
// Windows baseline here is x86-64-v2, which is below FMA, so on Windows every
// fused multiply add on a float32 is a call to fmaf in the UCRT. That fmaf is
// not always correctly rounded.
//
// Measured on Windows 11 against five triples chosen to be hard in different
// ways. Four came back matching a correctly rounded fused multiply add and one
// was a whole ulp out. The one that is wrong is not a near tie that could be
// argued either way: for 36.0, 0.001234811614267528 and 0.004893524572253227
// the exact result sits an eighth of an ulp from the value fmaf should return
// and seven eighths of an ulp from the value it does return. The double
// precision fma from the same library was right on all five, including the two
// written so that only the whole product would do, so this file replaces fmaf
// and leaves fma alone.
//
// That gap is what test_issue_30237 in the standard library SIMD test trips
// over. It evaluates the same polynomial twice, once at compile time and once
// at run time, and asserts the two agree. Compile time folding of llvm.fma is
// exact, so a run time fmaf that is an ulp out is a visible failure rather than
// a quiet one. See #221.
//
// Replacing a C runtime symbol is worth being explicit about. This is a static
// archive named on the link line and ucrt.lib arrives as a default library, so
// the linker takes this one and never reaches for the other, and everything in
// the image that calls fmaf gets this. It is not a duplicate definition, and if
// it ever becomes one the link says so by name.

#include <stdint.h>
#include <string.h>

static double from_bits(uint64_t bits) {
  double value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

static uint64_t to_bits(double value) {
  uint64_t bits;
  memcpy(&bits, &value, sizeof(bits));
  return bits;
}

// The method is the standard way to build a narrow fused multiply add out of a
// wider format, and it needs the wider one to carry at least two more bits of
// significand than the narrower, which 53 against 24 has to spare.
//
// A float times a float needs at most 48 bits, so the product in double is
// exact. Adding the third operand rounds once, and TwoSum recovers exactly what
// that rounding dropped. Knowing which way the exact result lies is enough:
// nudging the sum onto an odd significand first makes narrowing it to a float
// give the same answer as rounding the exact result once, which is the
// definition of what fmaf owes the caller.
float fmaf(float x, float y, float z) {
  double a = (double)x;
  double b = (double)y;
  double c = (double)z;

  double product = a * b;
  double sum = product + c;

  // TwoSum, which is exact as long as the addition neither overflows nor goes
  // subnormal. Neither can happen here. The largest product two floats can make
  // is about 2^256 and the smallest non zero one about 2^-298, and a double
  // reaches past both ends of that by a wide margin.
  double shifted = sum - product;
  double residual = (product - (sum - shifted)) + (c - shifted);

  // Which side of the sum the exact result is on. Written as two comparisons
  // rather than as a test against zero because an infinite or nan sum leaves
  // the residual a nan, a nan compares false against both of these, and falling
  // out here with the sum unchanged is the right answer in those cases.
  int grow;
  if (residual > 0.0) {
    grow = sum > 0.0;
  } else if (residual < 0.0) {
    grow = sum < 0.0;
  } else {
    return (float)sum;
  }

  // Increasing the bit pattern of a float increases its magnitude whichever
  // sign it has, because the sign lives in a bit of its own and everything
  // below it reads as a magnitude. The sum cannot be zero here, since an
  // addition that produced a zero without underflowing produced an exact one,
  // and that leaves the residual zero and returns above.
  uint64_t bits = to_bits(sum);
  if ((bits & 1) == 0) {
    sum = from_bits(grow ? bits + 1 : bits - 1);
  }
  return (float)sum;
}
