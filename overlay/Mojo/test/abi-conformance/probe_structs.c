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
// Struct probes. The place where the two calling conventions disagree most, and
// where they disagree in a way that is easy to state.
//
// Win64 looks at nothing but the size. A struct of exactly 1, 2, 4 or 8 bytes
// goes in one register, by value. Anything else is copied to memory by the
// caller and a pointer to the copy is passed instead, taking one register slot.
// There is no classification step and the field types never come into it.
//
// System V classifies. It cuts the struct into eight byte pieces, works out for
// each piece whether it is INTEGER or SSE by looking at what is in it, and hands
// out up to two registers from whichever files those pieces call for. Only
// something over sixteen bytes, or something containing an unaligned field,
// goes to memory.
//
// So a twelve byte struct of three ints is two integer registers on Linux and a
// hidden pointer on Windows. Sixteen bytes of two doubles is two SSE registers
// on Linux and a hidden pointer on Windows. And three bytes, which no
// convention passes in a sensible way, is one register on Linux and a hidden
// pointer on Windows. None of that produces a diagnostic when it goes wrong.
//
// Every struct here has an exact size with no tail padding, so that the size
// the convention keys on is the size the name says.

#include "Mojo/test/abi-conformance/probe.h"

#include <stdint.h>

//===----------------------------------------------------------------------===//
// The shapes
//===----------------------------------------------------------------------===//

// Sizes one through eight, all bytes, so that the size is exactly the field
// count and the alignment never rounds it up. Four of these sizes are ones
// Win64 passes in a register and four are ones it does not, which is the
// contrast worth having.
struct B1 {
  uint8_t f0;
};
struct B2 {
  uint8_t f0, f1;
};
struct B3 {
  uint8_t f0, f1, f2;
};
struct B4 {
  uint8_t f0, f1, f2, f3;
};
struct B5 {
  uint8_t f0, f1, f2, f3, f4;
};
struct B6 {
  uint8_t f0, f1, f2, f3, f4, f5;
};
struct B7 {
  uint8_t f0, f1, f2, f3, f4, f5, f6;
};
struct B8 {
  uint8_t f0, f1, f2, f3, f4, f5, f6, f7;
};

// The control case. Eight bytes of two integers, which both conventions put in
// a single integer register. If this one ever fails the problem is not the
// convention, it is something more basic.
struct TwoInts {
  int32_t a, b;
};

// Twelve bytes. Two integer registers on System V, a hidden pointer on Win64.
struct ThreeInts {
  int32_t a, b, c;
};

// Sixteen bytes of floating point. Two SSE registers on System V, a hidden
// pointer on Win64.
struct TwoDoubles {
  double a, b;
};

// Eight bytes with one field of each class. System V has to decide what the one
// eight byte piece is, and the rule is that a piece with any integer in it is
// INTEGER, so the float travels in an integer register with the int packed
// beside it. Win64 does not look, and passes eight bytes in an integer register
// for its own unrelated reason. Both end up in an integer register by different
// routes, which is exactly the sort of case that looks fine until the field
// order changes.
struct FloatAndInt {
  float a;
  int32_t b;
};

// Sixteen bytes of integers. The last size System V still passes in registers.
struct TwoLongs {
  int64_t a, b;
};

// Twenty four bytes. Over the limit for both, so memory either way, and it is
// here to confirm the agreed case still agrees.
struct ThreeLongs {
  int64_t a, b, c;
};

// A struct inside a struct, twelve bytes in total. System V flattens before it
// classifies, so this is classified exactly like ThreeInts and a compiler that
// treats the nested field as an indivisible unit gets a different answer.
struct Nested {
  struct TwoInts inner;
  int32_t c;
};

// Shapes that hold something other than a plain scalar. An array field is
// classified by what it is made of and how much of it there is, exactly like the
// same bytes spelled out as separate fields, and this says so out loud because
// it is the sort of rule that is easier to assume than to check.
//
// WithLong is here for a different reason. Nothing else in this suite can see a
// wrong C long. Everywhere else the width is absorbed, because a slot is eight
// bytes and the callee reads the low end of it. Inside a struct it moves the
// offset of every field after it and changes the size of the whole thing, which
// is the one place it turns into a wrong value rather than a wrong idea.
struct WithLong {
  long a;
  int32_t b;
  long c;
};

struct WithArray {
  uint32_t v[3];
};

struct WithLongArray {
  int64_t v[2];
};

struct WithCharArray {
  char v[5];
};


//===----------------------------------------------------------------------===//
// Sizes
//===----------------------------------------------------------------------===//
//
// Every shape is declared twice, once here and once in structs.mojo, and the
// whole suite rests on the two declarations describing the same thing. If they
// do not, the results mean nothing: a Mojo B3 that is four bytes rather than
// three is not the case the test says it is, and it would sail through on
// System V while testing something else entirely.
//
// So ask. The size is the thing both conventions key on, so it is also the
// thing worth agreeing about, and a mismatch here should be read before any
// other failure in the run.

#define SIZE_OF(name, type)          \
  int32_t name(void) {               \
    return (int32_t)sizeof(type);    \
  }

SIZE_OF(abi_size_b1, struct B1)
SIZE_OF(abi_size_b2, struct B2)
SIZE_OF(abi_size_b3, struct B3)
SIZE_OF(abi_size_b4, struct B4)
SIZE_OF(abi_size_b5, struct B5)
SIZE_OF(abi_size_b6, struct B6)
SIZE_OF(abi_size_b7, struct B7)
SIZE_OF(abi_size_b8, struct B8)
SIZE_OF(abi_size_two_ints, struct TwoInts)
SIZE_OF(abi_size_three_ints, struct ThreeInts)
SIZE_OF(abi_size_two_doubles, struct TwoDoubles)
SIZE_OF(abi_size_float_and_int, struct FloatAndInt)
SIZE_OF(abi_size_two_longs, struct TwoLongs)
SIZE_OF(abi_size_three_longs, struct ThreeLongs)
SIZE_OF(abi_size_nested, struct Nested)
SIZE_OF(abi_size_with_long, struct WithLong)
SIZE_OF(abi_size_with_array, struct WithArray)
SIZE_OF(abi_size_with_long_array, struct WithLongArray)
SIZE_OF(abi_size_with_char_array, struct WithCharArray)

#undef SIZE_OF

//===----------------------------------------------------------------------===//
// Passing
//===----------------------------------------------------------------------===//

#define I abi_probe_record_int
#define F abi_probe_record_float

void abi_struct_b1(struct B1 s) { I(s.f0); }

void abi_struct_b2(struct B2 s) {
  I(s.f0);
  I(s.f1);
}

void abi_struct_b3(struct B3 s) {
  I(s.f0);
  I(s.f1);
  I(s.f2);
}

void abi_struct_b4(struct B4 s) {
  I(s.f0);
  I(s.f1);
  I(s.f2);
  I(s.f3);
}

void abi_struct_b5(struct B5 s) {
  I(s.f0);
  I(s.f1);
  I(s.f2);
  I(s.f3);
  I(s.f4);
}

void abi_struct_b6(struct B6 s) {
  I(s.f0);
  I(s.f1);
  I(s.f2);
  I(s.f3);
  I(s.f4);
  I(s.f5);
}

void abi_struct_b7(struct B7 s) {
  I(s.f0);
  I(s.f1);
  I(s.f2);
  I(s.f3);
  I(s.f4);
  I(s.f5);
  I(s.f6);
}

void abi_struct_b8(struct B8 s) {
  I(s.f0);
  I(s.f1);
  I(s.f2);
  I(s.f3);
  I(s.f4);
  I(s.f5);
  I(s.f6);
  I(s.f7);
}

void abi_struct_two_ints(struct TwoInts s) {
  I(s.a);
  I(s.b);
}

void abi_struct_three_ints(struct ThreeInts s) {
  I(s.a);
  I(s.b);
  I(s.c);
}

void abi_struct_two_doubles(struct TwoDoubles s) {
  F(s.a);
  F(s.b);
}

void abi_struct_float_and_int(struct FloatAndInt s) {
  F(s.a);
  I(s.b);
}

void abi_struct_two_longs(struct TwoLongs s) {
  I(s.a);
  I(s.b);
}

void abi_struct_three_longs(struct ThreeLongs s) {
  I(s.a);
  I(s.b);
  I(s.c);
}

void abi_struct_nested(struct Nested s) {
  I(s.inner.a);
  I(s.inner.b);
  I(s.c);
}

//===----------------------------------------------------------------------===//
// Passing alongside other arguments
//===----------------------------------------------------------------------===//
//
// A struct on its own only says whether the struct arrived. These say whether it
// took the register slots it was supposed to, because anything that comes after
// it is wrong if it did not. On Win64 the hidden pointer for a large struct
// consumes one register slot exactly like an integer would, so the arguments
// after it shift by one against a convention that passed the struct in two.

void abi_struct_three_ints_then(struct ThreeInts s, int64_t a, int64_t b,
                                int64_t c) {
  I(s.a);
  I(s.b);
  I(s.c);
  I(a);
  I(b);
  I(c);
}

void abi_struct_after_three(int64_t a, int64_t b, int64_t c,
                            struct ThreeInts s) {
  I(a);
  I(b);
  I(c);
  I(s.a);
  I(s.b);
  I(s.c);
}

// The same idea with the floating point struct, where System V spends two SSE
// registers and Win64 spends one integer slot on the pointer. Trailing doubles
// then land somewhere different on each.
void abi_struct_two_doubles_then(struct TwoDoubles s, double a, double b) {
  F(s.a);
  F(s.b);
  F(a);
  F(b);
}

// An odd size, which Win64 always sends through memory, sitting between
// arguments on both sides of it.
void abi_struct_b3_between(int64_t a, struct B3 s, int64_t b) {
  I(a);
  I(s.f0);
  I(s.f1);
  I(s.f2);
  I(b);
}

#undef I
#undef F

//===----------------------------------------------------------------------===//
// Returning
//===----------------------------------------------------------------------===//
//
// Returns follow the same size rule on Win64: 1, 2, 4 or 8 bytes come back in
// RAX, and anything else is written through a hidden pointer the caller passes
// as an invisible first argument, which shifts every real argument along by
// one. System V classifies the return the way it classifies an argument, so a
// sixteen byte struct comes back in two registers there and through memory on
// Windows.
//
// Each of these adds one to every field rather than returning a constant,
// because a constant return can be right by accident when the argument never
// arrived.

struct B1 abi_ret_b1(struct B1 s) {
  s.f0 += 1;
  return s;
}

struct B3 abi_ret_b3(struct B3 s) {
  s.f0 += 1;
  s.f1 += 1;
  s.f2 += 1;
  return s;
}

struct B5 abi_ret_b5(struct B5 s) {
  s.f0 += 1;
  s.f1 += 1;
  s.f2 += 1;
  s.f3 += 1;
  s.f4 += 1;
  return s;
}

struct B7 abi_ret_b7(struct B7 s) {
  s.f0 += 1;
  s.f1 += 1;
  s.f2 += 1;
  s.f3 += 1;
  s.f4 += 1;
  s.f5 += 1;
  s.f6 += 1;
  return s;
}

struct B8 abi_ret_b8(struct B8 s) {
  s.f0 += 1;
  s.f1 += 1;
  s.f2 += 1;
  s.f3 += 1;
  s.f4 += 1;
  s.f5 += 1;
  s.f6 += 1;
  s.f7 += 1;
  return s;
}

struct TwoInts abi_ret_two_ints(struct TwoInts s) {
  s.a += 1;
  s.b += 1;
  return s;
}

struct ThreeInts abi_ret_three_ints(struct ThreeInts s) {
  s.a += 1;
  s.b += 1;
  s.c += 1;
  return s;
}

struct TwoDoubles abi_ret_two_doubles(struct TwoDoubles s) {
  s.a += 1.0;
  s.b += 1.0;
  return s;
}

struct FloatAndInt abi_ret_float_and_int(struct FloatAndInt s) {
  s.a += 1.0f;
  s.b += 1;
  return s;
}

struct TwoLongs abi_ret_two_longs(struct TwoLongs s) {
  s.a += 1;
  s.b += 1;
  return s;
}

struct ThreeLongs abi_ret_three_longs(struct ThreeLongs s) {
  s.a += 1;
  s.b += 1;
  s.c += 1;
  return s;
}

struct Nested abi_ret_nested(struct Nested s) {
  s.inner.a += 1;
  s.inner.b += 1;
  s.c += 1;
  return s;
}

// A return through the hidden pointer from a call that also has real arguments,
// which is where the shift the hidden pointer causes is easiest to get wrong.
struct ThreeInts abi_ret_three_ints_after(int64_t a, int64_t b,
                                          struct ThreeInts s) {
  abi_probe_record_int(a);
  abi_probe_record_int(b);
  s.a += 1;
  s.b += 1;
  s.c += 1;
  return s;
}

void abi_struct_with_long(struct WithLong s) {
  abi_probe_record_int(s.a);
  abi_probe_record_int(s.b);
  abi_probe_record_int(s.c);
}

// The same with a neighbour after it, so a struct whose size is wrong pushes
// something whose expected value is known independently.
void abi_struct_with_long_then(struct WithLong s, int64_t x) {
  abi_probe_record_int(s.a);
  abi_probe_record_int(s.b);
  abi_probe_record_int(s.c);
  abi_probe_record_int(x);
}

struct WithLong abi_ret_with_long(struct WithLong s) {
  s.a += 1;
  s.b += 1;
  s.c += 1;
  return s;
}

void abi_struct_with_array(struct WithArray s) {
  abi_probe_record_int(s.v[0]);
  abi_probe_record_int(s.v[1]);
  abi_probe_record_int(s.v[2]);
}

struct WithArray abi_ret_with_array(struct WithArray s) {
  s.v[0] += 1;
  s.v[1] += 1;
  s.v[2] += 1;
  return s;
}

// Sixteen bytes of array, which is past the size either convention will put in
// registers, so it goes through memory both ways and by different rules.
void abi_struct_with_long_array(struct WithLongArray s) {
  abi_probe_record_int(s.v[0]);
  abi_probe_record_int(s.v[1]);
}

// Five bytes, which is one of the sizes Win64 refuses to put in a register and
// System V still packs into one.
void abi_struct_with_char_array(struct WithCharArray s) {
  for (int i = 0; i < 5; i++) {
    abi_probe_record_int((int64_t)s.v[i]);
  }
}

struct WithCharArray abi_ret_with_char_array(struct WithCharArray s) {
  for (int i = 0; i < 5; i++) {
    s.v[i] += 1;
  }
  return s;
}
