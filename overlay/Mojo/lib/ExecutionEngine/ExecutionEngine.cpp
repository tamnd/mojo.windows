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

#include "Mojo/ExecutionEngine/ExecutionEngine.h"
#include "Mojo/ExecutionEngine/JIT/StaticArchiveLayer.h"
#include "Mojo/Support/Configuration.h"
#include "Support/ErrorOr.h"
#include "llvm/ExecutionEngine/JITLink/JITLink.h"
#include "llvm/ExecutionEngine/Orc/AbsoluteSymbols.h"
#include "llvm/ExecutionEngine/Orc/COFFPlatform.h"
#include "llvm/ExecutionEngine/Orc/Core.h"
#include "llvm/ExecutionEngine/Orc/Debugging/DebugInfoSupport.h"
#include "llvm/ExecutionEngine/Orc/Debugging/DebuggerSupportPlugin.h"
#include "llvm/ExecutionEngine/Orc/Debugging/ELFDebugObjectPlugin.h"
#include "llvm/ExecutionEngine/Orc/Debugging/PerfSupportPlugin.h"
#include "llvm/ExecutionEngine/Orc/EPCDynamicLibrarySearchGenerator.h"
#include "llvm/ExecutionEngine/Orc/MapperJITLinkMemoryManager.h"
#include "llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h"
#include "llvm/ExecutionEngine/Orc/SelfExecutorProcessControl.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/JITLoaderPerf.h"
#include "llvm/IR/Mangler.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/Process.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/TargetParser/Host.h"

#include <stdio.h>
#include <wchar.h>

using namespace M;
using namespace KGEN;

/// A standard name (that a user is unlikely to create) that we can use for a
/// JITDylib to define platform-specific symbols we want to be in the JIT'ed
/// address space.
static constexpr StringLiteral platformStdlibName = "$platform-stdlib";
static constexpr StringLiteral compilerRTlibName = "$compilerrt-lib";
static constexpr StringLiteral mlirclibName = "$mlirc-lib";

//===----------------------------------------------------------------------===//
// ExecutionEngine implementation
//===----------------------------------------------------------------------===//

/// Set up the ORC platform for the various different binary formats/platforms
/// we support. This requires that we have an ExecutionSession *and* an
/// ObjectLinkingLayer.
///
/// The main reason to use the platform like this is that it automatically sets
/// up the various symbols that complex code will need to execute on a target.
static ErrorOrSuccess setupPlatform(llvm::orc::JITDylib &platformStdlib,
                                    llvm::orc::ExecutionSession &session,
                                    llvm::orc::DylibManager &dylibMgr) {
  // Add the current process symbols in.
  // NOTE: COFF JIT currently doesn't support in process symbols, as it can
  // currently hit conflicts with symbols in the current COFF ORC runtime.
  auto generator = toModularErrorOr(
      llvm::orc::EPCDynamicLibrarySearchGenerator::GetForTargetProcess(
          session, dylibMgr));
  if (generator.isError())
    return generator.takeError();
  platformStdlib.addGenerator(std::move(*generator));

  // The generator above searches the modules the process already has loaded,
  // which is enough on the other two platforms and is not enough here. A
  // Windows build of mojo links the C runtime statically, so ucrtbase.dll is
  // not among those modules and nothing in the process exports `_setmode` or
  // `_write` for JIT'd code to find. Naming the three libraries outright also
  // takes the answer away from whatever order EnumProcessModules happens to
  // return, which is worth something for `memcpy`, since ntdll and ucrtbase
  // both have one.
  //
  // These are the system's own copies, found the way LoadLibrary finds them,
  // and the two that are already loaded cost a reference count and nothing
  // else. Between them they cover everything a Mojo program has needed so far:
  // the CRT entry points from ucrtbase, the console and handle calls from
  // kernel32, and `__chkstk` from either of the other two.
  if (session.getTargetTriple().isOSBinFormatCOFF()) {
    for (const char *library : {"ucrtbase.dll", "kernel32.dll", "ntdll.dll"}) {
      auto systemGenerator = toModularErrorOr(
          llvm::orc::EPCDynamicLibrarySearchGenerator::Load(session, dylibMgr,
                                                            library));
      if (systemGenerator.isError())
        return Error(Twine("error '") +
                     Twine(systemGenerator.getError()) + "' while loading " +
                     library);
      platformStdlib.addGenerator(std::move(*systemGenerator));
    }

    // Half of the printf and scanf family is not a function anywhere on a
    // Windows machine. The UCRT headers declare those names inline over
    // `__stdio_common_*`, so an ordinary program gets its own copy while it is
    // being compiled and ucrtbase exports nothing to match. JIT'd code has no
    // such moment and emits a plain call, which then has nothing to bind to.
    //
    // The other half does resolve, through ntdll, which carries its own copies
    // from the old NT C runtime. Those are not the UCRT functions and they
    // differ where it is easiest to notice, in floating point conversions, so
    // that half is the worse one. Defining these names outright settles both
    // cases, because a generator is only ever asked about a name the dylib does
    // not already have.
    //
    // A Windows build of mojo links the UCRT statically, so the addresses below
    // are our own copies, which are the ones that behave correctly. They are
    // also the reason for the preprocessor check: these are names out of a
    // Windows C library, and some of them are only spelled this way there.
#ifdef _WIN32
    llvm::orc::SymbolMap stdio;
    auto defineStdio = [&](StringRef name, auto *function) {
      stdio[session.intern(name)] = {
          llvm::orc::ExecutorAddr::fromPtr(function),
          llvm::JITSymbolFlags::Exported | llvm::JITSymbolFlags::Callable};
    };
    defineStdio("printf", &printf);
    defineStdio("vprintf", &vprintf);
    defineStdio("fprintf", &fprintf);
    defineStdio("vfprintf", &vfprintf);
    defineStdio("sprintf", &sprintf);
    defineStdio("vsprintf", &vsprintf);
    defineStdio("snprintf", &snprintf);
    defineStdio("vsnprintf", &vsnprintf);
    defineStdio("scanf", &scanf);
    defineStdio("fscanf", &fscanf);
    defineStdio("sscanf", &sscanf);
    defineStdio("_snprintf", &_snprintf);
    defineStdio("_vsnprintf", &_vsnprintf);
    // The two wide ones need spelling out. In C++ the UCRT headers give them a
    // template overload that deduces the size of an array argument, so the bare
    // name is an overload set rather than one address.
    defineStdio("swprintf",
                static_cast<int (*)(wchar_t *, size_t, const wchar_t *, ...)>(
                    &swprintf));
    defineStdio("vswprintf",
                static_cast<int (*)(wchar_t *, size_t, const wchar_t *,
                                    va_list)>(&vswprintf));
    if (auto errOr = toModularErrorOr(platformStdlib.define(
            llvm::orc::absoluteSymbols(std::move(stdio))));
        failed(errOr))
      return errOr.takeError();
#endif
  }

  return success();
}

/// Initialize the mlirc and CompilerRT dylib.
static ErrorOrSuccess
initializeCompilerRT(llvm::orc::ExecutionSession &session,
                     llvm::orc::DylibManager &dylibMgr, MojoConfig &cfg,
                     const llvm::DataLayout &layout,
                     const ExecutionEngineOptions &options) {
  std::error_code ec;

  // mlirc dylib. Grab the symbols from the current process.
  {
    auto *libJD = &session.createBareJITDylib(mlirclibName.str());
    libJD->addGenerator(llvm::cantFail(
        llvm::orc::EPCDynamicLibrarySearchGenerator::GetForTargetProcess(
            session, dylibMgr,
            [=](const llvm::orc::SymbolStringPtr &symbolStringPtr) {
              StringRef name = *symbolStringPtr;
              // On MachO, the symbol names start with `_`.
              return name.starts_with("mlir") || name.starts_with("_mlir");
            })));
  }

  // CompilerRT dylib.
  std::string compilerRTPath = cfg.getCompilerRTPath().str();
  if (!std::filesystem::exists(compilerRTPath, ec) || ec)
    return Error(std::string("unable to locate compiler_rt ") + compilerRTPath);

  auto *libJD = &session.createBareJITDylib(compilerRTlibName.str());

  SmallVector<StringRef> paths = options.libraryPaths;
  paths.push_back(compilerRTPath);

  for (StringRef libPath : paths) {
    auto generatorOr =
        toModularErrorOr(llvm::orc::EPCDynamicLibrarySearchGenerator::Load(
            session, dylibMgr, libPath.str().c_str()));
    if (generatorOr.isError()) {
      return Error(Twine("error '") + Twine(generatorOr.getError()) +
                   "' while loading compiler runtime library from '" +
                   libPath.str().c_str() + "'");
    }
    libJD->addGenerator(std::move(*generatorOr));
  }

  // Allow pulling in sanitizer methods from the current process, as we
  // currently can't activate any of these runtimes otherwise (they must
  // generally be loaded first in the host process).
  libJD->addGenerator(llvm::cantFail(
      llvm::orc::DynamicLibrarySearchGenerator::GetForCurrentProcess(
          layout.getGlobalPrefix(),
          [=](const llvm::orc::SymbolStringPtr &symbolStringPtr) {
            return llvm::any_of(ArrayRef<StringRef>{"__asan", "__tsan"},
                                [&](StringRef prefix) {
                                  return (*symbolStringPtr).starts_with(prefix);
                                });
          })));

  return success();
}

namespace {
/// Drops the exception unwinding tables out of every COFF object the JIT links.
///
/// A `.pdata` entry is three 32 bit offsets from the image base, and a linker
/// writes one by taking the address of what the entry describes and subtracting
/// the address of `__ImageBase`. JIT'd code is not in an image and has no base
/// to subtract, so JITLink invents `__ImageBase` as an undefined external,
/// nothing ever defines it, its address stays zero, and the subtraction leaves
/// the whole 64 bit address to be squeezed into 32 bits. The link then fails on
/// the first function that has unwind info, which is every function.
///
/// Nothing would read these tables even if they made it through. Handing them
/// to Windows is the ORC COFF platform's job and no platform is created here,
/// so they are relocated and then left for nobody. Dropping them costs what not
/// registering them already costs, which is that a Windows debugger cannot walk
/// out of a JIT'd frame.
class COFFUnwindSectionRemovalPlugin
    : public llvm::orc::ObjectLinkingLayer::Plugin {
public:
  void modifyPassConfig(llvm::orc::MaterializationResponsibility &,
                        llvm::jitlink::LinkGraph &graph,
                        llvm::jitlink::PassConfiguration &config) override {
    if (!graph.getTargetTriple().isOSBinFormatCOFF())
      return;

    // At the front, ahead of JITLink's own SEH pass, which ties each `.pdata`
    // block to the code it describes with a keep alive edge. Running after it
    // would leave those edges pointing at blocks that are no longer here.
    config.PrePrunePasses.insert(
        config.PrePrunePasses.begin(),
        [](llvm::jitlink::LinkGraph &g) -> llvm::Error {
          // `.xdata` goes too. It is only ever reached through `.pdata`, and it
          // carries the same kind of image relative pointer to a handler.
          for (StringRef name : {".pdata", ".xdata"})
            if (llvm::jitlink::Section *section = g.findSectionByName(name))
              g.removeSection(*section);
          return llvm::Error::success();
        });
  }

  llvm::Error
  notifyFailed(llvm::orc::MaterializationResponsibility &) override {
    return llvm::Error::success();
  }

  llvm::Error notifyRemovingResources(llvm::orc::JITDylib &,
                                      llvm::orc::ResourceKey) override {
    return llvm::Error::success();
  }

  void notifyTransferringResources(llvm::orc::JITDylib &,
                                   llvm::orc::ResourceKey,
                                   llvm::orc::ResourceKey) override {}
};
} // namespace

M::ErrorOr<std::unique_ptr<ExecutionEngine>>
ExecutionEngine::create(ExecutionEngineOptions options,
                        const llvm::TargetMachine &tm) {
  // Create the data layout from the target machine.
  const llvm::DataLayout &layout = tm.createDataLayout();
  const llvm::Triple &tt = tm.getTargetTriple();

  // Construct the ExecutionSession. The user may have passed in an
  // ExecutorProcessControl that we need to use.
  std::unique_ptr<llvm::orc::ExecutorProcessControl> epc =
      std::move(options.epc);

  // The JIT-link memory manager is owned by the ObjectLinkingLayer so build it
  // up front.
  //
  // JIT mapper reservation granularity. Every fresh reservation by LLVM's
  // MapperJITLinkMemoryManager is rounded up to this size and mmapped
  // PROT_READ|PROT_WRITE, so it sets a floor on the JIT region's virtual
  // footprint — which counts against RLIMIT_AS on Linux. Large compiles
  // still work: the mapper reserves additional slabs on demand.
  //
  // Do not increase this unless you know what you are doing. In the past,
  // setting this to 1 GiB caused sporadic OoM crashes on memory-constrained
  // runners.
  size_t slabSize = size_t{64} * 1024 * 1024;
  auto managerOr =
      toModularErrorOr(llvm::orc::MapperJITLinkMemoryManager::CreateWithMapper<
                       llvm::orc::InProcessMemoryMapper>(slabSize));
  if (managerOr.isError())
    return managerOr.takeError();

  if (!epc) {
    auto pageSize = toModularErrorOr(llvm::sys::Process::getPageSize());
    if (pageSize.isError())
      return pageSize.takeError();

    epc = std::make_unique<llvm::orc::SelfExecutorProcessControl>(
        std::make_shared<llvm::orc::SymbolStringPool>(),
        std::make_unique<llvm::orc::InPlaceTaskDispatcher>(), tt, *pageSize);
  }
  auto sessionPtr =
      std::make_unique<llvm::orc::ExecutionSession>(std::move(epc));

  // Create a default DylibManager from the ExecutorProcessControl.
  auto dylibMgrOr = toModularErrorOr(
      sessionPtr->getExecutorProcessControl().createDefaultDylibMgr());
  if (dylibMgrOr.isError())
    return dylibMgrOr.takeError();

  // Now we can actually create the ExecutionEngine.
  auto ee = std::unique_ptr<ExecutionEngine>(
      new ExecutionEngine(std::move(sessionPtr), layout));
  ee->dylibMgr = std::move(*dylibMgrOr);

  // Open the config object so we can use it.
  auto cfgOr = MojoConfig::open();
  if (cfgOr.isError())
    return cfgOr.takeError();
  MojoConfig cfg = std::move(*cfgOr);

  // Construct the object linking layer; it takes ownership of the manager.
  ee->objectLayer = std::make_unique<llvm::orc::ObjectLinkingLayer>(
      *ee->executionSession, std::move(*managerOr));

  // Before anything else gets a look at a Windows object, so that the unwind
  // tables are gone by the time the passes that care about them run.
  if (tt.isOSBinFormatCOFF())
    ee->objectLayer->addPlugin(
        std::make_unique<COFFUnwindSectionRemovalPlugin>());

  // Construct the platform stdlib - this way we don't have to worry about
  // whether or not we have it later on.
  llvm::orc::JITDylib &platformStdlib =
      ee->executionSession->createBareJITDylib(platformStdlibName.str());

  // If we have the platform support library, use it. This requires the
  // compilation target to be a subset of the host process, so disable it for
  // cross-compilation.
  if (!options.crossCompiling) {
    if (auto err =
            setupPlatform(platformStdlib, *ee->executionSession, *ee->dylibMgr))
      return err.takeError();
  }

  if (options.registerDebugPlugins) {
    llvm::orc::ExecutionSession &session = *ee->executionSession;

    // Get the registrar for the GDB JIT loader interface.
    if (tt.isOSBinFormatMachO()) {
      // Create and register the JIT DebugInfo plugin. The GDB alloc-action
      // symbol is resolved from the session's bootstrap JITDylib, which the
      // in-process executor populates automatically.
      auto plugin =
          toModularErrorOr(llvm::orc::GDBJITDebugInfoRegistrationPlugin::Create(
              session, session.getBootstrapJITDylib()));
      if (plugin.isError())
        return plugin.takeError();

      ee->objectLayer->addPlugin(std::move(*plugin));
    } else if (tt.isOSBinFormatELF()) {
      // Register the ELFDebugObjectPlugin.
      llvm::Error error = llvm::Error::success();
      auto plugin = std::make_unique<llvm::orc::ELFDebugObjectPlugin>(
          session, /*RequireDebugSections=*/true, error);
      if (auto errOr = toModularErrorOr(std::move(error)); failed(errOr))
        return errOr.takeError();
      ee->objectLayer->addPlugin(std::move(plugin));
    }
  }

  if (options.registerPerfPlugins) {
    auto debugInfo = llvm::orc::DebugInfoPreservationPlugin::Create();
    if (!debugInfo)
      return toModularError(debugInfo.takeError());
    ee->objectLayer->addPlugin(std::move(debugInfo.get()));
    auto perf = std::make_unique<llvm::orc::PerfSupportPlugin>(
        ee->objectLayer->getExecutionSession().getExecutorProcessControl(),
        llvm::orc::ExecutorAddr::fromPtr(&llvm_orc_registerJITLoaderPerfStart),
        llvm::orc::ExecutorAddr::fromPtr(&llvm_orc_registerJITLoaderPerfEnd),
        llvm::orc::ExecutorAddr::fromPtr(&llvm_orc_registerJITLoaderPerfImpl),
        true, true);
    ee->objectLayer->addPlugin(std::move(perf));
  }

  // Add the platform dylib to the search order.
  if (auto err = ee->addToSearchOrder(platformStdlibName, &platformStdlib))
    return err.takeError();

  // Prepare the CompilerRT dylib.
  if (auto err = initializeCompilerRT(*ee->executionSession, *ee->dylibMgr, cfg,
                                      layout, options))
    return err.takeError();

  return std::move(ee);
}

ErrorOr<std::unique_ptr<ExecutionEngine>>
ExecutionEngine::createWithStandardLayers(ExecutionEngineOptions options,
                                          const llvm::TargetMachine &tm) {
  auto engineOr = ExecutionEngine::create(std::move(options), tm);
  if (engineOr.isError())
    return engineOr.takeError();

  // Add the standard layers.
  (*engineOr)->addLayer<StaticArchiveLayer>((*engineOr)->getLinkingLayer());

  return std::move(*engineOr);
}

ExecutionEngine::ExecutionEngine(
    std::unique_ptr<llvm::orc::ExecutionSession> session,
    const llvm::DataLayout &dl)
    : executionSession(std::move(session)),
      // Parse the layout so that we own the underlying memory. DataLayout is a
      // bit weird, it seems like it has some internal data structures that
      // every instance shares.
      dataLayout(dl.getStringRepresentation()) {}

ExecutionEngine::~ExecutionEngine() {
  if (!executionSession)
    return;

  // If the execution engine has initialized the ORC runtime, the ELFNix and
  // COFF platform implementations need manual shutdown. The MachOPlatform
  // implementation is more sophisticated and performs shutdown automatically
  // through the JITLink LinkGraph allocation actions.
  const llvm::Triple &triple = executionSession->getTargetTriple();
  if (executionSession->getPlatform() &&
      // FIXME: On Windows, this complains about symbol not found. The Windows
      // build seems happy even without the shutdown, so disable it for now.
      (triple.isOSBinFormatELF() /*|| triple.isOSBinFormatCOFF()*/)) {
    ErrorOr<CompiledFunc> shutdown =
        lookup(triple.isOSBinFormatELF() ? "__orc_rt_elfnix_platform_shutdown"
                                         : "__orc_rt_coff_platform_shutdown");
    if (shutdown.isError()) {
      llvm::report_fatal_error(
          Twine("failed to find ELF/COFF platform shutdown function: ") +
          shutdown.takeError().get());
    }
    struct OrcRTCWrapperFunctionResult {
      char *data;
      size_t size;
    };
    shutdown->invoke<OrcRTCWrapperFunctionResult, char *, size_t>(nullptr, 0);
  }

  if (auto err = executionSession->endSession())
    executionSession->reportError(std::move(err));
}

ErrorOr<CompiledFunc> ExecutionEngine::lookup(StringRef symbol) {
  return lookupWithSearchOrder(searchOrder, symbol);
}

ErrorOr<CompiledFunc> ExecutionEngine::lookup(StringRef libName,
                                              StringRef symbol) {
  llvm::orc::JITDylib *dylib = executionSession->getJITDylibByName(libName);
  if (!dylib)
    return Error("could not find JITDylib with name: " + libName);

  return lookupWithSearchOrder(llvm::orc::makeJITDylibSearchOrder({dylib}),
                               symbol);
}

ErrorOrSuccess
ExecutionEngine::runProgram(StringRef libName, StringRef entryPoint,
                            function_ref<ErrorOrSuccess(void *)> runFn) {
  using namespace llvm::orc;
  // There is not global ctor/dtor in mojo.

  // Lookup the entry point symbol and directly invoke it rather than going
  // through the runtime.
  ErrorOr<CompiledFunc> mainFn = lookup(entryPoint);
  if (mainFn.isError())
    return mainFn.takeError();
  if (ErrorOrSuccess err = runFn(mainFn->getFunctionPointer()))
    return err.takeError();
  return success();
}

llvm::orc::SymbolStringPtr
KGEN::ExecutionEngine::mangleAndIntern(StringRef name) {
  std::string mangledName;
  llvm::raw_string_ostream mangledNameStream(mangledName);
  llvm::Mangler::getNameWithPrefix(mangledNameStream, name, dataLayout);
  return executionSession->intern(mangledName);
}

ErrorOrSuccess ExecutionEngine::addToSearchOrder(StringRef name,
                                                 llvm::orc::JITDylib *dylib) {
  [[maybe_unused]] auto [_, didInsert] = knownDylibs.insert(name);
  assert(didInsert && "must have uniquely-named dylibs");

  // If this isn't the platform stdlib, setup CompilerRT and mlirc.
  if (name != platformStdlibName) {
    dylib->addToLinkOrder(
        *executionSession->getJITDylibByName(compilerRTlibName));
    dylib->addToLinkOrder(*executionSession->getJITDylibByName(mlirclibName));

    // The platform stdlib is in the search order a lookup starts from, but
    // until now it was in nobody's link order, which is what a symbol gets
    // resolved through once materialization is under way. On ELF and Mach-O
    // that gap never showed, because dlsym on the compiler runtime handle keeps
    // walking into that library's own dependencies and the C runtime is one of
    // them. GetProcAddress does no such walking: it reads one module's export
    // table and stops. So on Windows the only thing that can answer for a
    // libc symbol is the platform stdlib, and it has to be reachable from here.
    //
    // Last, so that anything the Mojo runtime defines still wins over the
    // system copy of the same name.
    if (executionSession->getTargetTriple().isOSBinFormatCOFF())
      dylib->addToLinkOrder(
          *executionSession->getJITDylibByName(platformStdlibName));
  }

  // Use higher preference for newer dylibs.
  searchOrder.insert(searchOrder.begin(),
                     {dylib, llvm::orc::JITDylibLookupFlags::MatchAllSymbols});
  return success();
}

ErrorOr<CompiledFunc> ExecutionEngine::lookupWithSearchOrder(
    const llvm::orc::JITDylibSearchOrder &order, llvm::StringRef symbol) {
  // Look up this symbol with the search order provided.
  llvm::Expected<llvm::orc::ExecutorSymbolDef> sym =
      executionSession->lookup(order, mangleAndIntern(symbol));
  if (sym)
    return CompiledFunc(sym->getAddress().toPtr<void *>());

  // Check to see if any of the layers have errors.
  auto found = llvm::find_if(
      layers, [](const auto &layer) { return layer->hasError(); });
  // If not, return the error returned by the ORC.
  if (found == layers.end())
    return toModularError(sym.takeError());

  // Add the additional context from the layer's error.
  return Error(llvm::toString(sym.takeError()) +
               " (from the layer: " + (*found)->takeError().get() + ")");
}
