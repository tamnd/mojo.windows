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

#ifndef KGEN_COMPILERRT_MEMORY_H
#define KGEN_COMPILERRT_MEMORY_H

#include "Support/SymbolExport.h"

#ifndef _MSC_VER
#include <unistd.h>
#endif // _MSC_VER

// The guard above is right that <unistd.h> does not exist on Windows, but
// dropping the include also drops ssize_t, which is POSIX and which the MSVC
// CRT has no declaration of anywhere. llvm-c/DataTypes.h typedefs it under
// _MSC_VER, and that is where the rest of this tree gets it from, though almost
// always by accident: nearly every use of ssize_t here sits in a file that
// reaches an LLVM header for some other reason. This one does not, so it says
// so out loud. Same fix and same reasoning as AsyncRT/Runtime/Globals/Globals.h.
#include "llvm/Support/DataTypes.h"

// Set allocators to system memalign/free to support asan
// this function is NOT thread safe and needs to be called
// before any allocations
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT void
KGEN_CompilerRT_SetAsanAllocators();

/// Returns an alignment allocated memory. If the alignment value is not
/// positive, then the default alignment is used.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT void *
KGEN_CompilerRT_AlignedAlloc(ssize_t alignment, ssize_t size);

/// Frees memory allocated via KGEN_CompilerRT_AlignedAlloc.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT void
KGEN_CompilerRT_AlignedFree(void *ptr);

#endif // KGEN_COMPILERRT_MEMORY_H
