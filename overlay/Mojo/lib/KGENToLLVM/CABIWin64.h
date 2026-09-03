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

#ifndef KGEN_LIB_KGENTOLLVM_CABIWIN64_H
#define KGEN_LIB_KGENTOLLVM_CABIWIN64_H

#include "CABILowering.h"

namespace M::KGEN {

/// Implementation of the Microsoft x64 calling convention, the one used by
/// every Windows target on x86-64 regardless of which compiler produced the
/// other side of the call.
///
/// The whole convention, as far as this class is concerned, is one sentence
/// from the Microsoft ABI documentation: any argument that does not fit in
/// eight bytes, or whose size is not one of 1, 2, 4 or 8 bytes, is passed by
/// reference. Everything else is passed in a single register as an integer of
/// that exact width.
///
/// That is much less work than System V and it is worth being explicit about
/// what is missing rather than leaving it to look like an oversight:
///
/// - There is no eightbyte classification. A struct is not taken apart and
///   there is no notion of a field's class deciding anything. Only the total
///   size matters.
/// - There is no separate float rule. A struct holding a single `float` goes
///   in an integer register as an `i32`, and a struct of two `double`s is 16
///   bytes so it goes by reference. Only a bare, unwrapped `float` or `double`
///   argument uses an SSE register, and that falls out of the type without
///   any help from here.
/// - There is no register budget and so no rollback-to-stack rule, which is
///   why this class does not override `computeSignatureInfo` the way
///   `SystemVABIInfo` does. Win64 gives an argument the fourth register or the
///   stack purely by its position, and nothing about that changes how the
///   argument is coerced. The LLVM backend already knows the convention from
///   the triple and does the placement.
/// - Variadic arguments follow the same rule as fixed ones. Passing a `double`
///   through `...` duplicates it into the matching integer register as well,
///   but that is the backend's job and does not show up in the coercion.
///
/// Return values use the same size test. One, two, four or eight bytes come
/// back in RAX as an integer, and anything else uses a hidden pointer.
///
/// The reference implementation this was checked against is clang's
/// `WinX86_64ABIInfo` for `x86_64-pc-windows-msvc`, and the checked-in
/// expectations in `Mojo/test/kgen/pop-to-llvm/extern-c-abi-win64.mlir` were
/// taken from what clang actually emits rather than from a reading of the
/// documentation. See `docs/abi.md`.
class Win64ABIInfo : public CABIInfo {
public:
  Win64ABIInfo(mlir::MLIRContext *ctx, const LLVMDataLayout &dataLayout);

protected:
  CoercionInfo classifyArgumentType(mlir::Type type, mlir::Location loc,
                                    bool isVariadicArg) const override;

  CoercionInfo classifyReturnType(mlir::Type type,
                                  mlir::Location loc) const override;

private:
  /// The one rule, shared by arguments and return values.
  ///
  /// \param useSRet If true, an aggregate that cannot be passed in a register
  ///                uses the hidden result pointer. If false, it is passed as
  ///                a pointer to a caller-owned copy.
  CoercionInfo classifyAggregate(mlir::Type type, mlir::Location loc,
                                 bool useSRet) const;
};

} // namespace M::KGEN

#endif // KGEN_LIB_KGENTOLLVM_CABIWIN64_H
