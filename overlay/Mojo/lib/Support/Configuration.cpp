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

#include "Mojo/Support/Configuration.h"
#include "Support/Configuration.h"
#include "Support/PlatformLibNames.h"
#include "llvm/Support/FileSystem.h"
#include <variant> // IWYU pragma: keep (std::visit)

using namespace M;
using namespace M::KGEN;

#define _STRINGIFY(str) #str
#define _X_STRINGIFY(str) _STRINGIFY(str)
#define STRINGIFY_MOJO_CONFIG(path) _X_STRINGIFY(MOJO_CONFIG_SECTION) path

#ifndef MOJO_CONFIG_SECTION // NOLINT(ifdef), Wundef doesn't handle the define
#error "Expected MOJO_CONFIG_SECTION to be set"
#endif

ErrorOr<std::filesystem::path> MojoConfig::getConfigFilePath() const {
  if (const Config *val = std::get_if<Config>(&configSource))
    return val->getConfigFilePath();
  return Error("Configuration file path unavailable from settings");
}

static Config &getConfigFrom(Config &config) { return config; }

static Config &getConfigFrom(Config *config) { return *config; }

Config &MojoConfig::getConfig() {
  return std::visit([](auto &src) -> Config & { return getConfigFrom(src); },
                    configSource);
}

StringRef MojoConfig::getValue(StringLiteral key) {
  return getConfig().getValue(key);
}

StringRef MojoConfig::getPath(StringLiteral key, StringRef relativePath) {
  return getConfig().getPath(key, relativePath);
}

//===----------------------------------------------------------------------===//
// MojoConfig
//===----------------------------------------------------------------------===//

ErrorOr<MojoConfig> MojoConfig::open() {
  ErrorOr<Config> config = Config::open();
  if (config.isError())
    return config.takeError();
  return MojoConfig(std::move(*config));
}

MojoConfig MojoConfig::fromContext(ContextRef ctx) {
  return MojoConfig(ctx->get<Config>());
}

//===----------------------------------------------------------------------===//
// Parser Configurations
//===----------------------------------------------------------------------===//

void MojoConfig::getParserImportPaths(SmallVectorImpl<StringRef> &paths) {
  StringRef importPaths = getValue(STRINGIFY_MOJO_CONFIG(".import_path"));
  importPaths.split(paths, ',', /*MaxSplit=*/-1, /*KeepEmpty=*/false);
}

//===----------------------------------------------------------------------===//
// Plugin Configurations
//===----------------------------------------------------------------------===//

SmallVector<std::string> MojoConfig::getPluginPaths() {
  SmallVector<StringRef> paths;
  StringRef pluginPaths = getValue(STRINGIFY_MOJO_CONFIG(".mojo_plugin_paths"));
  pluginPaths.split(paths, ';', /*MaxSplit=*/-1, /*KeepEmpty=*/false);
  return SmallVector<std::string>(paths.begin(), paths.end());
}

//===----------------------------------------------------------------------===//
// LLDB Configurations
//===----------------------------------------------------------------------===//

// The paths below all name a file inside this installation that this process is
// about to load: a debugger plugin, the compiler runtime, the Jupyter kernel.
// Those are built for the machine the compiler runs on, so the name is a
// question about this host and not about whatever `mojo build` is targeting.
//
// It used to be answered here, by a two way `#ifdef __APPLE__` that fell through
// to `.so` on anything that was not macOS. On Windows that produced a search for
// `libKGENCompilerRTShared.so`, which is a confusing thing to fail on because it
// looks nothing like a Windows problem. `PlatformLibrary` already answered the
// same question from the Bazel platform, so ask it instead of answering again.
//
// `getPath` copies the string it is given into the config map before returning
// a reference to it, so handing it a temporary is fine.
static std::string sharedLibPath(StringRef stem) {
  return "lib/" + PlatformLibrary::getSharedLibraryName(stem);
}

StringRef MojoConfig::getLLDBPluginPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".lldb_plugin_path"),
                 sharedLibPath("MojoLLDB"));
}

StringRef MojoConfig::getLLDBPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".lldb_path"), "bin/mojo-lldb");
}

//===----------------------------------------------------------------------===//
// JIT Configurations
//===----------------------------------------------------------------------===//

StringRef MojoConfig::getCompilerRTPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".compilerrt_path"),
                 sharedLibPath("KGENCompilerRTShared"));
}

StringRef MojoConfig::getMGPRTPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".mgprt_path"), sharedLibPath("MGPRT"));
}

//===----------------------------------------------------------------------===//
// Driver Configurations
//===----------------------------------------------------------------------===//

StringRef MojoConfig::getDriverPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".driver_path"), "bin/mojo");
}

StringRef MojoConfig::getJupyterPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".jupyter_path"),
                 sharedLibPath("MojoJupyter"));
}

StringRef MojoConfig::getLSPServerPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".lsp_server_path"),
                 "bin/mojo-lsp-server");
}

StringRef MojoConfig::getMBlackPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".mblack_path"), "bin/mblack");
}

StringRef MojoConfig::getREPLEntryPoint() {
  return getPath(STRINGIFY_MOJO_CONFIG(".repl_entry_point"),
                 "lib/mojo-repl-entry-point");
}

StringRef MojoConfig::getLinkerDriver() {
  return getValue(STRINGIFY_MOJO_CONFIG(".linker_driver"));
}

StringRef MojoConfig::getLLDPath() {
  return getPath(STRINGIFY_MOJO_CONFIG(".lld_path"), "bin/lld");
}

void MojoConfig::setLLDPathOverride(StringRef path) {
  Config::setGlobalValue(STRINGIFY_MOJO_CONFIG(".lld_path"), path);
}

void MojoConfig::appendSystemLibraryLinkArgs(SmallVectorImpl<StringRef> &libs) {
  if (auto maybeSystemLibsArg =
          getConfig().maybeGetValue(STRINGIFY_MOJO_CONFIG(".system_libs"))) {
    maybeSystemLibsArg.value().split(libs, ',', /*MaxSplit=*/-1,
                                     /*KeepEmpty=*/false);
  }
}

void MojoConfig::appendSharedObjectLinkArgs(SmallVectorImpl<StringRef> &args) {
  if (auto maybeArgs = getConfig().maybeGetValue(
          STRINGIFY_MOJO_CONFIG(".shared_object_libs"))) {
    maybeArgs.value().split(args, ',', /*MaxSplit=*/-1, /*KeepEmpty=*/false);
  }
}

void MojoConfig::appendSharedLibraryLinkArgs(
    SmallVectorImpl<StringRef> &args,
    llvm::function_ref<std::string(StringRef)> nameSharedLibrary) {
  StringRef sharedLibsArg = getValue(STRINGIFY_MOJO_CONFIG(".shared_libs"));
  if (!sharedLibsArg.empty()) {
    sharedLibsArg.split(args, ',', /*MaxSplit=*/-1, /*KeepEmpty=*/false);
  } else {
    // Mini-hack: We make up some imaginary config sections so that the config
    // will intern some strings for us. Otherwise, we'd have to intern the whole
    // string and then parse it back out.
    args.push_back("-Xlinker");
    args.push_back("-rpath");
    args.push_back("-Xlinker");
    args.push_back(getPath(STRINGIFY_MOJO_CONFIG(".shared_libs_lib"), "lib"));
  }

  // The AsyncRT Mojo bindings ship in max-core, not in the mojo compiler
  // package, so a base Mojo install simply does not have them. Link them
  // whenever they are installed: a `.mojoc` records no cc dependencies, so
  // this is the only way `mojo build` can learn that an imported package
  // (`max`) needs them. Bazel builds resolve the same library through the
  // dependency graph instead and never reach this.
  //
  // This one is not quite like the others above it. The file being named here
  // is linked into the binary `mojo build` is producing, so the right answer is
  // the target's and not the host's, and that is why the name comes in from the
  // caller. A Linux host cross compiling for Windows used to find
  // `lib/libAsyncRTMojoBindings.so`, decide it existed, and hand a `.so` to
  // lld-link, which is not a thing lld-link can read.
  StringRef bindings =
      getPath(STRINGIFY_MOJO_CONFIG(".shared_libs_artmb"),
              "lib/" + nameSharedLibrary("AsyncRTMojoBindings"));
  if (llvm::sys::fs::exists(bindings))
    args.push_back(bindings);
}

StringRef MojoConfig::getMojoConfigSection() {
  return _X_STRINGIFY(MOJO_CONFIG_SECTION);
}
