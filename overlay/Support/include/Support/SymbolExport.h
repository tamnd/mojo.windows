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
// This file defines macros for exporting symbols.
//
//===----------------------------------------------------------------------===//

#ifndef SUPPORT_EXPORT_H
#define SUPPORT_EXPORT_H

#if (defined(_WIN32) || defined(__CYGWIN__))
#ifdef MODULAR_BUILDING_LIBRARY
#define MODULAR_VISIBILITY_EXPORT __declspec(dllexport)
#else
#define MODULAR_VISIBILITY_EXPORT __declspec(dllimport)
#endif
#else
#define MODULAR_VISIBILITY_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
#define MODULAR_EXPORT extern "C" MODULAR_VISIBILITY_EXPORT
#else
#define MODULAR_EXPORT MODULAR_VISIBILITY_EXPORT
#endif

// We have to have a way to turn off exports when we're building as a static
// lib - MSVC doesn't allow dllimport/dllexport on static library functions.
#ifndef MODULAR_NO_EXPORT
#define MODULAR_CXX_EXPORT MODULAR_VISIBILITY_EXPORT
#else
#define MODULAR_CXX_EXPORT
#endif

// Default visibility on ELF and Mach-O, nothing at all on Windows.
//
// For a symbol whose definition lives in a static library that every consumer
// links directly, but which still has to be reachable from outside whatever
// shared library that static library ends up inside.  The build compiles with
// -fvisibility=hidden, so on ELF and Mach-O that needs saying and default
// visibility says all of it.
//
// On Windows it is a question with no good answer, because dllexport and
// dllimport describe a DLL boundary and there is no DLL boundary here.  Saying
// either one produces a reference to an import table entry that no import
// library will ever have, so the right thing to say is nothing, and every
// consumer resolves the ordinary definition out of the static library the way
// it would resolve any other.
//
// MODULAR_NO_EXPORT is the same idea applied to a whole translation unit at
// once.  This one is per declaration, which is what you want when a header
// declares some things that live in a DLL and some things that do not.
#if (defined(_WIN32) || defined(__CYGWIN__))
#define MODULAR_CXX_STATIC_VISIBLE
#else
#define MODULAR_CXX_STATIC_VISIBLE __attribute__((visibility("default")))
#endif

// For CompilerRT we need the runtime entry points to have unmangled names,
// but currently do not wish to give them default visibility in any dylib
// they end up within.
#define COMPILERRT_EXPORT extern "C"

#if (defined(_WIN32) || defined(__CYGWIN__))
#ifdef MODULAR_BUILDING_COMPILERRT
#define COMPILERRT_VISIBILITY_EXPORT __declspec(dllexport)
#else
#define COMPILERRT_VISIBILITY_EXPORT __declspec(dllimport)
#endif
#else
#define COMPILERRT_VISIBILITY_EXPORT __attribute__((visibility("default")))
#endif

#if (defined(_WIN32) || defined(__CYGWIN__))
#ifdef MODULAR_BUILDING_DRIVER
#define DRIVER_VISIBILITY_EXPORT __declspec(dllexport)
#else
#define DRIVER_VISIBILITY_EXPORT __declspec(dllimport)
#endif
#else
#define DRIVER_VISIBILITY_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
#define MODULAR_DRIVER_EXPORT extern "C" DRIVER_VISIBILITY_EXPORT
#else
#define MODULAR_DRIVER_EXPORT DRIVER_VISIBILITY_EXPORT
#endif

#endif // SUPPORT_EXPORT_H
