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
// Variadic probes. The rest of the suite calls functions whose signature the
// caller can see. These are the ones where it cannot, and the two conventions
// take opposite approaches to that.
//
// Win64 barely changes anything. Arguments still go into the four register slots
// by position, and the only extra rule is that a floating point variadic
// argument goes into the SSE register and into the integer register that shares
// its slot, because the callee does not know which one to read and reads the
// integer one when it is walking a va_list.
//
// System V changes a great deal. The callee's va_start spills the argument
// registers into a save area so that va_arg can walk them, and it decides how
// many SSE registers to spill by reading AL, which the caller is required to
// set to the number of vector registers it used. A caller that leaves AL alone
// is not passing a wrong value, it is telling the callee to spill a number of
// registers that has nothing to do with the call, and what happens next depends
// on what was in AL from whatever ran before. That is the single worst failure
// mode in this whole area, because it is not deterministic.
//
// So these probes matter more than their number suggests. They do not, as I
// expected before measuring, catch a wrong C long. A variadic slot on x86-64 is
// eight bytes like a fixed one, in both conventions, so va_arg advances a whole
// slot whether long is four bytes or eight and the width is absorbed here too.
// The long probe below stays anyway, because that is a fact about x86-64 rather
// than about varargs, and AAPCS on arm64 sizes a variadic slot by the type.

#include "Mojo/test/abi-conformance/probe.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define I abi_probe_record_int
#define F abi_probe_record_float

// The count is the one fixed argument. It is not there to make the test tidy,
// it is there because a variadic function needs at least one named parameter
// for va_start to anchor to, and because the callee has no other way to know
// when to stop.
void abi_va_ints(int32_t count, ...) {
  va_list ap;
  va_start(ap, count);
  for (int32_t i = 0; i < count; i++) {
    I(va_arg(ap, int64_t));
  }
  va_end(ap);
}

void abi_va_doubles(int32_t count, ...) {
  va_list ap;
  va_start(ap, count);
  for (int32_t i = 0; i < count; i++) {
    F(va_arg(ap, double));
  }
  va_end(ap);
}

// Alternating, starting with an integer. Both of the rules above are live here
// at once: the doubles need the dual register treatment on Windows and they are
// what AL is counting on Linux.
void abi_va_mixed(int32_t count, ...) {
  va_list ap;
  va_start(ap, count);
  for (int32_t i = 0; i < count; i++) {
    if (i % 2 == 0) {
      I(va_arg(ap, int64_t));
    } else {
      F(va_arg(ap, double));
    }
  }
  va_end(ap);
}

// All doubles and enough of them to use every SSE register the conventions hand
// out, which is where a wrong AL does the most damage on Linux.
void abi_va_all_doubles(int32_t count, ...) {
  va_list ap;
  va_start(ap, count);
  for (int32_t i = 0; i < count; i++) {
    F(va_arg(ap, double));
  }
  va_end(ap);
}

// Twelve, so the list runs off the end of the register save area and va_arg has
// to start reading the caller's stack instead. The seam between the two is a
// place a caller can be wrong without being wrong about anything else.
void abi_va_many(int32_t count, ...) {
  va_list ap;
  va_start(ap, count);
  for (int32_t i = 0; i < count; i++) {
    I(va_arg(ap, int64_t));
  }
  va_end(ap);
}

// The default argument promotions. A variadic argument narrower than int is
// promoted to int and a float is promoted to double, by the caller, because the
// callee cannot ask for anything narrower. va_arg(ap, int) after a caller that
// passed a short reads a whole int and gets whatever the caller left in the rest
// of it.
void abi_va_promoted(int32_t count, ...) {
  va_list ap;
  va_start(ap, count);
  for (int32_t i = 0; i < count; i++) {
    if (i % 2 == 0) {
      I(va_arg(ap, int));
    } else {
      F(va_arg(ap, double));
    }
  }
  va_end(ap);
}

// long through a va_list. Written expecting this to be the case the width tests
// could not reach, on the reasoning that va_arg advances by the width it was
// told rather than by a slot size. That is true on some platforms and it is not
// true here: a variadic slot on x86-64 is eight bytes like every other slot, so
// building this with a 64 bit long on Windows still passes. Kept because it is
// the shape that will start failing on arm64, and because a probe that documents
// a measured non-difference is worth its twelve lines.
void abi_va_longs(int32_t count, ...) {
  va_list ap;
  va_start(ap, count);
  for (int32_t i = 0; i < count; i++) {
    I((int64_t)va_arg(ap, long));
  }
  va_end(ap);
}

// A variadic return value, since nothing above has one.
int64_t abi_va_sum(int32_t count, ...) {
  int64_t total = 0;
  va_list ap;
  va_start(ap, count);
  for (int32_t i = 0; i < count; i++) {
    total += va_arg(ap, int64_t);
  }
  va_end(ap);
  return total;
}

// ===--------------------------------------------------------------------=== //
// The real thing
// ===--------------------------------------------------------------------=== //
//
// Everything above is a variadic function written for this test. This part is
// the platform's own, which is the case that actually has to work, and it is
// worth having because a probe written here shares a compiler and a set of
// assumptions with the rest of the file while the C runtime shares neither.

enum { ABI_TEXT_SIZE = 128 };

static char g_text[ABI_TEXT_SIZE];

// The address as an integer rather than as a pointer. The Mojo side hands it
// straight back as the first argument to snprintf, and an address in a register
// is an address in a register whichever type the caller spelled it with, so
// this keeps the test from depending on how Mojo spells a pointer.
int64_t abi_text_buffer(void) { return (int64_t)(intptr_t)g_text; }

int32_t abi_text_size(void) { return ABI_TEXT_SIZE; }

// The format string, handed out the same way, so the Mojo side does not have to
// produce a null terminated C string to run this test.
int64_t abi_text_format(void) {
  static const char format[] = "%d:%lld:%.2f:%s";
  return (int64_t)(intptr_t)format;
}

int64_t abi_text_argument(void) {
  static const char argument[] = "tail";
  return (int64_t)(intptr_t)argument;
}

// C makes the same call and compares. Comparing against a literal written here
// would be comparing against a guess about how this platform's C runtime
// formats a double, which is not the thing under test.
int32_t abi_text_matches_reference(void) {
  char reference[ABI_TEXT_SIZE];
  snprintf(reference, sizeof(reference), "%d:%lld:%.2f:%s", 42,
           1234567890123LL, 2.5, "tail");
  return strcmp(g_text, reference) == 0 ? 1 : 0;
}

// What ended up in the buffer, for the failure message. Returned a byte at a
// time because the Mojo side has no reason to own a string type for this.
int32_t abi_text_byte(int32_t index) {
  if (index < 0 || index >= ABI_TEXT_SIZE) {
    return -1;
  }
  return (int32_t)(unsigned char)g_text[index];
}

void abi_text_clear(void) { memset(g_text, 0, sizeof(g_text)); }

#undef I
#undef F
