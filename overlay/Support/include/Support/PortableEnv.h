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
// setenv and unsetenv, on a platform whose C runtime has neither.
//
// Both are POSIX rather than C, and the MSVC runtime implements C.  What it has
// instead is _putenv_s, which is the same idea with a different signature and
// no way to say "only if it is not already set".  Everything that wants to
// set an environment variable in a test or a benchmark wants the POSIX
// spelling, so this header supplies it rather than asking every caller to
// branch.
//
// The two functions go in the global namespace, under their POSIX names, which
// is not the usual advice and is right here.  These are not new interfaces
// being introduced, they are one platform's missing half of an interface the
// rest of the code already uses, and the alternative is an #ifdef at every
// call site wrapping a call that would otherwise be identical.  On a
// non-Windows target this header is nothing but an include of <cstdlib>, so
// the real declarations are the ones in scope and there is no shadowing to
// reason about.
//
// Scope is deliberately small.  There is no putenv, no clearenv and no environ,
// because nothing here needs them and each one has its own Windows story.
//
//===----------------------------------------------------------------------===//

#ifndef SUPPORT_PORTABLEENV_H
#define SUPPORT_PORTABLEENV_H

#include <cstdlib>

#ifdef _WIN32

#include <stdlib.h>

/// Set an environment variable, leaving it alone if overwrite is zero and the
/// variable already has a value.  Returns zero on success and -1 on failure, as
/// POSIX does, rather than the errno_t that _putenv_s returns.
inline int setenv(const char *name, const char *value, int overwrite) {
  if (!overwrite && std::getenv(name) != nullptr)
    return 0;
  return _putenv_s(name, value) == 0 ? 0 : -1;
}

/// Remove an environment variable.  An empty value is how _putenv_s is told to
/// delete rather than to set, which is documented behaviour and not a trick.
inline int unsetenv(const char *name) {
  return _putenv_s(name, "") == 0 ? 0 : -1;
}

#endif // _WIN32

#endif // SUPPORT_PORTABLEENV_H
