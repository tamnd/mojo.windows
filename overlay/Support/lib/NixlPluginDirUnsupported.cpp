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
// NIXL plugin discovery for targets where NIXL does not exist.
//
// This is not a stub standing in for work not yet done, which is the difference
// between it and CrashReportingUnsupported.cpp.  NIXL is a Linux GPU cluster
// component and its plugins are ELF shared objects staged in a layout produced
// by a Linux build.  There is nothing on Windows for these functions to find,
// and there will not be.
//
// The answers below are the same ones NixlPluginDir.cpp already gives on a Linux
// host with no GPU, which the header calls out as a case callers must handle
// without erroring, because it also covers macOS and CPU-only machines.  So this
// is not a new behaviour for anyone, it is an existing one reached sooner.
//
//===----------------------------------------------------------------------===//

#ifdef _WIN32

#include "Support/NixlPluginDir.h"

#include <filesystem>
#include <optional>

using namespace M;

bool M::stagesRequestedBackend(const std::filesystem::path &) { return false; }

bool M::preloadStagedFabricLibs(const std::filesystem::path &) { return false; }

std::optional<std::filesystem::path>
M::resolveNixlPluginDir(const std::filesystem::path &, bool) {
  return std::nullopt;
}

#endif // _WIN32
