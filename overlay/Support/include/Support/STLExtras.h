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

#ifndef SUPPORT_STL_EXTRAS_H
#define SUPPORT_STL_EXTRAS_H

#include "Support/AlignedAlloc.h"
#include "Support/LogicalResult.h"
#include "llvm/ADT/STLExtras.h"
#include <cstddef>
#include <type_traits>

namespace M {

/// Converts an enumeration to its underlying type. Note this function is
/// available as part of the STL in C++23.
template <typename Enum>
constexpr std::underlying_type_t<Enum> to_underlying(Enum e) {
  return static_cast<std::underlying_type_t<Enum>>(e);
}

//===----------------------------------------------------------------------===//
// failableInterleave
//===----------------------------------------------------------------------===//

/// Call a function for each element in the range and a second function in
/// between every pair of elements. Either function can fail, in which case
/// iteration aborts and the function as a whole fails.
template <typename ForwardIterator, typename UnaryFunctor,
          typename NullaryFunctor>
auto failableInterleave(ForwardIterator begin, ForwardIterator end,
                        UnaryFunctor eachFn, NullaryFunctor betweenFn)
    -> decltype(betweenFn()) {
  if (begin == end)
    return success();
  if (failed(eachFn(*begin)))
    return failure();
  ++begin;
  for (; begin != end; ++begin) {
    if (failed(betweenFn()) || failed(eachFn(*begin)))
      return failure();
  }
  return success();
}

template <typename Container, typename UnaryFunctor, typename NullaryFunctor>
auto failableInterleave(const Container &c, UnaryFunctor eachFn,
                        NullaryFunctor betweenFn) {
  return failableInterleave(c.begin(), c.end(), eachFn, betweenFn);
}

//===----------------------------------------------------------------------===//
// contains_if
//===----------------------------------------------------------------------===//

/// Returns true if there is at least one element in the range that satisfies
/// the unary predicate.
template <typename Range, typename UnaryPredicate>
bool contains_if(Range &&range, UnaryPredicate pred) {
  auto it = llvm::find_if(range, pred);
  return it != llvm::adl_end(range);
}

//===----------------------------------------------------------------------===//
// AlignedAllocator
//===----------------------------------------------------------------------===//

/// An allocator that can be used in STL data structures with a dynamic
/// alignment value.
template <typename T>
class AlignedAllocator {
public:
  using value_type = T;
  using pointer = T *;

  AlignedAllocator(size_t align) : align(align) {}

  /// Rebinding constructor.  An allocator has been required to be convertible
  /// from the same allocator for another type since C++11, because a container
  /// generally has to allocate something other than its own value_type: a list
  /// allocates nodes, and MSVC's containers allocate a _Container_proxy, which
  /// is what makes their iterator debugging work.  libstdc++ and libc++ never
  /// need it for the way this allocator is used, which is why it went missing.
  /// The alignment carries across, since it is the only state there is.
  template <typename U>
  AlignedAllocator(const AlignedAllocator<U> &other) : align(other.align) {}

  /// n is a count of T, not a count of bytes.  The multiplication was missing,
  /// which is a genuine under-allocation and not a Windows thing at all.  It
  /// has not caused trouble yet only because every use of this allocator so far
  /// is AlignedAllocator<char>, where the two happen to agree.  The rebinding
  /// constructor above makes that stop being true.
  pointer allocate(size_t n) {
    return (pointer)alignedAlloc(align, n * sizeof(T));
  }

  void deallocate(pointer p, size_t n) { alignedFree(p); }

  /// Two of these can free each other's memory when they allocate the same way,
  /// which for this allocator means the same alignment.  Containers use this to
  /// decide whether they can steal a buffer on move assignment rather than copy
  /// it element by element, so leaving it out is not free.
  template <typename U>
  bool operator==(const AlignedAllocator<U> &other) const {
    return align == other.align;
  }

  template <typename U>
  bool operator!=(const AlignedAllocator<U> &other) const {
    return !(*this == other);
  }

private:
  /// So the rebinding constructor and the comparisons can read align out of an
  /// AlignedAllocator of a different type.  They are all the same template, but
  /// two instantiations of a template are unrelated classes.
  template <typename U>
  friend class AlignedAllocator;

  size_t align;
};

} // namespace M

#endif // SUPPORT_STL_EXTRAS_H
