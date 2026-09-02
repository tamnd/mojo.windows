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
// CrashReporting for targets where Crashpad is not built.
//
// Crashpad itself supports Windows, and the sources for it are in the archive
// this project already fetches.  What is missing is the BUILD file work, since
// the one we get wires up Linux and macOS and explicitly leaves out compat/win.
// That is a real job and it is not this one.  Until it is done, a Windows build
// takes these definitions instead, which lets everything that calls into crash
// reporting keep compiling and linking without any of it being conditional at
// the call site.
//
// Nothing here reports a crash.  It is the honest behaviour for a target that
// has no handler to report to, and it stays that way only until the handler is
// wired up, at which point this file goes away rather than growing.
//
//===----------------------------------------------------------------------===//

#include "Support/CrashReporting/CrashReporting.h"

#include "Support/Error.h"
#include "Support/ErrorOr.h"

#include <filesystem>

using namespace M;

std::filesystem::path
M::getCrashDatabasePath(const std::filesystem::path &dataFolder) {
  return dataFolder / "crashdb";
}

ErrorOr<std::filesystem::path> M::getCrashpadHandlerPath(Config *) {
  return Error("crash reporting is not built for this platform");
}

void M::initCrashpadForProgram(StringRef, StringRef, StringRef, Config *) {
  // Deliberately silent.  The Crashpad build prints only when initialization
  // was attempted and failed, and a line on every single run of the compiler
  // saying that a feature nobody asked for is missing would be worse than
  // saying nothing.  getCrashpadHandlerPath above returns an error for anyone
  // who wants to know.
}

void M::generateNonFatalDump() {
  // Nothing to dump to.
}
