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

#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <string_view>

// setenv is POSIX and the MSVC CRT does not have it. _putenv_s is the closest
// thing, same two arguments, declared in <stdlib.h> so nothing here needs
// windows.h, but it always overwrites, so the overwrite flag has to be honoured
// out here instead of being passed along.
//
// One difference that cannot be papered over: _putenv_s with an empty value
// removes the variable rather than setting it to the empty string, because Win32
// has no way to represent an environment variable that exists and is empty.
// Neither call below can produce an empty value today, but that is a property of
// the call sites and not of this function, so it is written down rather than
// asserted.
static void setEnv(const char *key, const char *value, bool overwrite) {
#ifdef _WIN32
  if (!overwrite && std::getenv(key))
    return;
  _putenv_s(key, value);
#else
  setenv(key, value, overwrite ? 1 : 0);
#endif
}

static std::string_view getRequiredEnv(const char *key) {
  char *value = std::getenv(key);
  if (!value) {
    std::cerr << "Missing required env var: " << key << std::endl;
    abort();
  }

  return value;
}

// Convert comma-separated relative paths to absolute paths based on the
// current working directory. This must be called before changing directories.
static void makeImportPathsAbsolute() {
  char *importPath = std::getenv("MODULAR_MOJO_MAX_IMPORT_PATH");
  if (!importPath || importPath[0] == '\0')
    return;

  std::filesystem::path cwd = std::filesystem::current_path();
  std::string result;
  std::istringstream iss(importPath);
  std::string path;

  while (std::getline(iss, path, ',')) {
    if (!result.empty())
      result += ',';

    std::filesystem::path fsPath(path);
    if (fsPath.is_relative()) {
      // Convert relative path to absolute based on current runfiles directory
      result += (cwd / fsPath).lexically_normal().generic_string();
    } else {
      result += path;
    }
  }

  setEnv("MODULAR_MOJO_MAX_IMPORT_PATH", result.c_str(), /*overwrite=*/true);
}

__attribute__((visibility("default"))) __attribute__((constructor)) void
fix_bazel_paths() {
  if (std::getenv("RUNNING_DIRECTLY") == nullptr) {
    // Either not running through bazel or being run transitively, in which
    // case the main target being run is responsible for configuration
    return;
  }

  std::filesystem::path workspaceDir =
      getRequiredEnv("BUILD_WORKSPACE_DIRECTORY");
  std::filesystem::path derivedDir = workspaceDir / ".derived";

  // Find modular.cfg in derived for runtime dependencies
  setEnv("MODULAR_HOME", derivedDir.generic_string().c_str(),
         /*overwrite=*/false);
  auto pwd = std::filesystem::current_path();
  if (pwd.filename() == "_main") {
    // Convert import paths to absolute before changing directories, since they
    // are relative to the runfiles directory.
    makeImportPathsAbsolute();
    std::filesystem::current_path(getRequiredEnv("BUILD_WORKING_DIRECTORY"));
  }
}
