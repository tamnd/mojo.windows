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
// The one place in this project that includes <windows.h>.
//
// windows.h is not an ordinary header.  It defines several hundred macros with
// names an ordinary program might reasonably want, and which of them it defines
// depends on macros you set before including it.  That makes it order dependent
// and configuration dependent, which is exactly the sort of thing that works in
// every file until it does not work in one, and then costs a day.  Routing every
// use through one header means the configuration is decided once, in a place
// with room to say why.
//
// The rule is: no .cpp or .h in this project includes <windows.h> directly.
// Include this instead.  It is safe to include unconditionally, since on a
// non-Windows target it expands to nothing.
//
//===----------------------------------------------------------------------===//

#ifndef SUPPORT_WINDOWSHEADER_H
#define SUPPORT_WINDOWSHEADER_H

#ifdef _WIN32

// Cuts winsock 1, OLE, RPC and a dozen other subsystems out of windows.h.  The
// one that matters is winsock: without this, windows.h pulls in winsock.h, and
// any file that later reaches winsock2.h gets a few hundred redefinition errors,
// because the two headers define the same structs incompatibly and neither one
// guards against the other.  Nothing here has hit that yet.  It is set anyway,
// because the failure arrives all at once, in a file that did nothing wrong, the
// first time something in the dependency graph wants modern sockets.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

// NOMINMAX turns off the min and max function-like macros in minwindef.h, which
// otherwise break every use of std::numeric_limits<T>::max().  The Windows arm of
// the cc toolchain already passes -DNOMINMAX, because that has to hold for far
// more code than includes this header, notably all of boringssl.  It is repeated
// here so that this header is correct read on its own, rather than correct only
// as long as a build file a long way away keeps doing something.
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#endif // _WIN32

#endif // SUPPORT_WINDOWSHEADER_H
