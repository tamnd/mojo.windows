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
// The recording buffer the probes write into, shared between the translation
// units that hold probes. Only the probes use this. The Mojo side reaches the
// buffer through the accessors below, which it calls by name through
// external_call and never sees a declaration of.

#ifndef MOJO_TEST_ABI_CONFORMANCE_PROBE_H
#define MOJO_TEST_ABI_CONFORMANCE_PROBE_H

#include <stdint.h>

// Slots are written in argument order, so slot n holds argument n whatever its
// type. The reader knows the signature it called and so knows which of the two
// accessors to use.
void abi_probe_record_int(int64_t value);
void abi_probe_record_float(double value);

void abi_probe_reset(void);
int32_t abi_probe_count(void);
int64_t abi_probe_int(int32_t index);
double abi_probe_float(int32_t index);

#endif  // MOJO_TEST_ABI_CONFORMANCE_PROBE_H
