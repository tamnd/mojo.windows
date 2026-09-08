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

#ifndef ASYNCRT_INIT_INIT_H
#define ASYNCRT_INIT_INIT_H

#include "AsyncRT/Runtime/CPUDevice.h"
#include "Support/Context.h"
#include "Support/ErrorOr.h"

#include <optional>

namespace M {
namespace Init {

class Options {
public:
  Options() = default;
  Options(const Options &) = default;
  Options &withForceDisableCrashReporting(bool v = true) {
    forceDisableCrashReporting = v;
    return *this;
  }

  Options &withCPUDeviceOptions(
      const AsyncRT::CPUDeviceOptions &v = AsyncRT::CPUDeviceOptions()) {
    cpuDeviceOptions.emplace(v);
    return *this;
  }

  /// Returns true if crash-reporting and cpuDevice options match \p other.
  bool operator==(const Options &other) const {
    if (forceDisableCrashReporting != other.forceDisableCrashReporting)
      return false;
    return cpuDeviceOptions == other.cpuDeviceOptions;
  }

  bool operator!=(const Options &other) const { return !(*this == other); }

  bool forceDisableCrashReportingEnabled() const {
    return forceDisableCrashReporting;
  }

  std::optional<AsyncRT::CPUDeviceOptions> getCPUDeviceOptions() const {
    return cpuDeviceOptions;
  }

private:
  bool forceDisableCrashReporting = false;
  std::optional<AsyncRT::CPUDeviceOptions> cpuDeviceOptions;

  friend ErrorOr<ContextRef> getOrCreateContext(StringRef, const Options &,
                                                StringRef);
};

// All three of these say MODULAR_CXX_STATIC_VISIBLE rather than
// MODULAR_CXX_EXPORT.  Init is a static library and every consumer links its
// object files directly, so there is no DLL boundary here and nothing for
// dllexport or dllimport to describe.  MODULAR_CXX_EXPORT was resolving to
// dllimport, because only modular_shared_library defines
// MODULAR_BUILDING_LIBRARY and this target is not one, which sent every caller
// looking for an import table entry that no import library has.  Same thing
// that Support:Context ran into, same answer, and the long version of why is
// in SymbolExport.h.  On ELF and Mach-O this is no change at all.

// Creates the process-wide \c M::Context, reports a fatal error if a global
// context already exists. Intended for when there is a single point where the
// context is created.
MODULAR_CXX_STATIC_VISIBLE ErrorOr<ContextRef>
createContext(StringRef programName, const Options &options = {},
              StringRef subCommand = "");

/// Returns a reference to the existing process-wide \c M::Context, or creates
/// it if it doesn't already exist. Throws a fatal error if the \p options
/// requested do not match those used by the existing context. This function
/// should only be used when there is multiple possible paths to creating a
/// context and the order cannopt be guaranteed. Using createContext() and
/// getContext() is preferred when possible.
MODULAR_CXX_STATIC_VISIBLE ErrorOr<ContextRef>
getOrCreateContext(StringRef programName, const Options &options = {},
                   StringRef subCommand = "");

/// Returns a reference to the existing process-wide \c M::Context, reports a
/// fatal error if no context has been created yet.
MODULAR_CXX_STATIC_VISIBLE ContextRef getContext();

} // namespace Init
} // namespace M

#endif // ASYNCRT_INIT_INIT_H
