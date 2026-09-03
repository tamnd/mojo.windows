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

#include "CABIWin64.h"
#include "LLVMLoweringUtils.h"
#include "mlir/Dialect/LLVMIR/LLVMTypes.h"
#include "mlir/IR/BuiltinTypes.h"
#include "llvm/Support/MathExtras.h"

using namespace M;
using namespace M::KGEN;

//===----------------------------------------------------------------------===//
// Constructor
//===----------------------------------------------------------------------===//

Win64ABIInfo::Win64ABIInfo(mlir::MLIRContext *ctx,
                           const LLVMDataLayout &dataLayout)
    : CABIInfo(ctx, dataLayout) {}

//===----------------------------------------------------------------------===//
// Argument Classification
//===----------------------------------------------------------------------===//

CoercionInfo Win64ABIInfo::classifyArgumentType(mlir::Type type,
                                                mlir::Location loc,
                                                bool isVariadicArg) const {
  // Win64 has no separate rule for variadic arguments. A `double` passed
  // through `...` is duplicated into the matching integer register as well as
  // its SSE register, so that a callee with no prototype can find it, but that
  // is a placement decision the backend makes from the triple and it does not
  // change the type the argument is coerced to.
  (void)isVariadicArg;

  // An array never reaches a C function by value, so this only happens through
  // a hand written signature. Pass it by reference, which is what the size rule
  // below would say for every array big enough to be interesting anyway.
  if (isa<mlir::LLVM::LLVMArrayType>(type))
    return CoercionInfo::indirectArgument(/*useByval=*/false);

  return classifyAggregate(type, loc, /*useSRet=*/false);
}

//===----------------------------------------------------------------------===//
// Return Value Classification
//===----------------------------------------------------------------------===//

CoercionInfo Win64ABIInfo::classifyReturnType(mlir::Type type,
                                              mlir::Location loc) const {
  return classifyAggregate(type, loc, /*useSRet=*/true);
}

//===----------------------------------------------------------------------===//
// The Size Rule
//===----------------------------------------------------------------------===//

CoercionInfo Win64ABIInfo::classifyAggregate(mlir::Type type,
                                             mlir::Location loc,
                                             bool useSRet) const {
  // Scalars, pointers and vectors are already in the shape the convention
  // wants and pass through untouched. A bare `float` lands in an SSE register
  // and a bare `__m128` lands in a whole one, and neither needs a coercion to
  // get there.
  auto structType = dyn_cast<mlir::LLVM::LLVMStructType>(type);
  if (!structType)
    return CoercionInfo{};

  int64_t size = CabiUtils::getStructSize(structType, dataLayout);

  // "Any argument that doesn't fit in 8 bytes, or is not 1, 2, 4, or 8 bytes,
  // must be passed by reference." Note that this is a test on the total size
  // and nothing else: a 16 byte struct of two doubles goes by reference here
  // even though System V would hand it over in two SSE registers, and a 3 byte
  // struct goes by reference even though System V widens it to an i24 and
  // passes it in one.
  //
  // A zero sized struct is not a C type, but it can be built here, and it is
  // caught by this test rather than falling through to an integer of no width.
  if (size > 8 || !llvm::isPowerOf2_64(static_cast<uint64_t>(size)))
    return useSRet ? CoercionInfo::sretReturn()
                   : CoercionInfo::indirectArgument(/*useByval=*/false);

  // The remaining sizes are exactly 1, 2, 4 and 8, and each becomes the
  // integer of that width. This applies whatever the struct holds, so a
  // wrapped `float` becomes an `i32` and travels in an integer register. That
  // is the single most surprising thing about this convention and the reason
  // a Windows target that went through the System V classifier reads its
  // floats out of the wrong register file.
  return CabiUtils::classifySmallIntegerStruct(size, ctx);
}
