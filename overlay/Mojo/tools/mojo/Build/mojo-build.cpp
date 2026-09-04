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

#include "mojo-build.h"
#include "../Common/Compilation.h"

#include <algorithm>

#include "AsyncRT/CompilerSupport/Context.h"
#include "Cache/CachedTransform.h"
#include "Init/Init.h"
#include "Mojo/Compiler/KGENCompiler.h"
#include "Mojo/Compiler/ObjectCompiler.h"
#include "Mojo/Compiler/Target/TargetBackend.h"
#include "Mojo/KGENDialect/KGENOps.h"
#include "Mojo/MojoParser/EntryPoint.h"
#include "Mojo/POPDialect/POPTypes.h"
#include "Mojo/Support/Configuration.h"
#include "Mojo/Support/Constants.h"
#include "Mojo/ToolCommon/CompilationOptions.h"
#include "Mojo/ToolCommon/InitAllDialects.h"
#include "Support/Compiler/Diags.h"
#include "Support/Config.h"
#include "Support/DebugInfoDialect/IR/DebugInfoDialect.h"
#include "Support/Driver/DiagnosticFormat.h"
#include "Support/Driver/DriverSupport.h"
#include "Support/FileSystemExtras.h"
#include "Support/LLVMForwardDecls.h"
#include "Support/LogicalResult.h"
#include "Support/MDialect/MAttrs.h"
#include "Target/TargetTraits.h"

#include "mlir/Dialect/Index/IR/IndexDialect.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Diagnostics.h"
#include "mlir/IR/DialectRegistry.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/Pass/PassManager.h"
#include "mlir/Support/FileUtilities.h"
#include "mlir/Support/Timing.h"
#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"
#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/DiagnosticIDs.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/TargetInfo.h"
#include "clang/Basic/TargetOptions.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Option/ArgList.h"
#include "llvm/Option/OptTable.h"
#include "llvm/Option/Option.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/FormatVariadic.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Process.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/ToolOutputFile.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/TargetParser/Triple.h"

#ifdef KGEN_ENABLE_PASS_OPTIONS
#include "Mojo/ToolCommon/CLOptions.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Process.h"
#endif // KGEN_ENABLE_PASS_OPTIONS

using namespace M;
using namespace KGEN;
using namespace mlir;

#define DEBUG_TYPE "mojo-build"

//===----------------------------------------------------------------------===//
// Command line argument parsing
//===----------------------------------------------------------------------===//

#define DRIVER_OPTIONS_PATH "Build/BuildOptions.inc"
#include "Support/Driver/OptTable.inc"

namespace {
struct BuildOptTable : public llvm::opt::PrecomputedOptTable {
  BuildOptTable()
      : llvm::opt::PrecomputedOptTable(OptionStrTable, OptionPrefixesTable,
                                       InfoTable, OptionPrefixesUnion) {}
};

//===----------------------------------------------------------------------===//
// Target information helper functions
//===----------------------------------------------------------------------===//

/// Normalize a target triple string to canonical form with all components.
/// First applies LLVM's normalization (handles reordering), then fills in
/// missing components with "unknown" for clearer user output.
/// Example: "aarch64" -> "aarch64-unknown-unknown"
static std::string normalizeTriple(StringRef tripleStr) {
  // First let LLVM handle reordering (e.g., "-pc-i386" -> "i386-pc-unknown")
  llvm::Triple triple(llvm::Triple::normalize(tripleStr));
  StringRef vendorName = triple.getVendorName();
  StringRef osName = triple.getOSName();
  StringRef envName = triple.getEnvironmentName();
  // Then fill in missing components with "unknown" for clarity
  return (llvm::Twine(triple.getArchName()) + "-" +
          (vendorName.empty() ? "unknown" : vendorName) + "-" +
          (osName.empty() ? "unknown" : osName) +
          (envName.empty() ? "" : "-" + envName))
      .str();
}

/// Simple diagnostic consumer that prints errors to stderr.
class StderrDiagConsumer : public clang::DiagnosticConsumer {
public:
  void HandleDiagnostic(clang::DiagnosticsEngine::Level level,
                        const clang::Diagnostic &info) override {
    if (level >= clang::DiagnosticsEngine::Error) {
      SmallString<128> message;
      info.FormatDiagnostic(message);
      llvm::errs() << "error: " << message << "\n";
    }
  }
};

/// Get the list of valid CPUs for a target triple using clang.
/// Returns an empty vector if the target is invalid.
static std::vector<std::string> getValidCPUsForTarget(StringRef triple) {
  clang::IntrusiveRefCntPtr<clang::DiagnosticIDs> diagIDs(
      new clang::DiagnosticIDs());
  clang::DiagnosticOptions diagOpts;
  StderrDiagConsumer diagConsumer;
  clang::DiagnosticsEngine diags(diagIDs, diagOpts, &diagConsumer,
                                 /*ShouldOwnClient=*/false);

  auto targetOpts = std::make_shared<clang::TargetOptions>();
  targetOpts->Triple = triple;

  std::unique_ptr<clang::TargetInfo> targetInfo(
      clang::TargetInfo::CreateTargetInfo(diags, *targetOpts.get()));

  std::vector<std::string> cpus;
  if (targetInfo) {
    SmallVector<StringRef, 128> cpuRefs;
    targetInfo->fillValidCPUList(cpuRefs);
    for (StringRef cpu : cpuRefs)
      cpus.push_back(cpu.str());
  }
  return cpus;
}

/// Print the targets this build can generate code for.
static int printSupportedTargets() {
  llvm::InitializeAllTargets();
  llvm::InitializeAllTargetMCs();

  // An LLVM backend being linked in is necessary but not sufficient: emission
  // additionally requires a registered `TargetBackend`. Filter through the same
  // registry `--emit` consults so this list cannot advertise a target that then
  // fails to build.
  std::vector<std::pair<std::string, std::string>> targets;
  for (const llvm::Target &tgt : llvm::TargetRegistry::targets()) {
    llvm::Triple triple;
    triple.setArch(llvm::Triple::getArchTypeForLLVMName(tgt.getName()));
    if (TargetBackendRegistry::get().lookup(triple).isError())
      continue;
    targets.emplace_back(tgt.getName(), tgt.getShortDescription());
  }
  // Sort alphabetically for consistent, scannable output.
  llvm::sort(targets);

  llvm::outs() << "Registered Targets:\n";

  // If no targets found, something is wrong with the LLVM build. Handle
  // gracefully.
  if (targets.empty()) {
    llvm::outs() << "  No targets found.\n";
    return EXIT_SUCCESS;
  }

  for (const auto &[name, desc] : targets)
    llvm::outs() << "  " << name << " - " << desc << "\n";

  return EXIT_SUCCESS;
}

/// Print valid CPU names for a target triple.
static int printSupportedCpus(StringRef userTriple) {
  if (userTriple.empty()) {
    llvm::errs() << "error: --print-supported-cpus requires --target-triple "
                    "to be specified\n";
    llvm::errs() << "Use --print-supported-targets to see available "
                    "architectures.\n";
    return EXIT_FAILURE;
  }

  llvm::InitializeAllTargets();
  llvm::InitializeAllTargetMCs();

  std::string normalized = normalizeTriple(userTriple);
  std::vector<std::string> cpus = getValidCPUsForTarget(normalized);

  if (cpus.empty()) {
    // This likely means invalid target.
    // Clang already printed an error via StderrDiagConsumer, add guidance.
    llvm::errs() << "Use --print-supported-targets to see available "
                    "architectures.\n";
    return EXIT_FAILURE;
  }

  llvm::outs() << "Available CPUs for target " << normalized << ":\n";
  for (const std::string &cpu : cpus)
    llvm::outs() << "  " << cpu << "\n";
  return EXIT_SUCCESS;
}

/// Print the supported accelerator architectures declared by the
/// registered `TargetTraits`.
static int printSupportedAccelerators() {
  // The '#' characters below are intentional.
  // These delimiters allow Mojo tests to extract the architecture list
  // without needing to know specific architecture prefixes.
  llvm::outs() << "Supported Accelerator Architectures:\n\n#\n";

  // Print one section per target, name-sorted.
  llvm::SmallVector<const TargetTraits *> targets;
  for (const std::unique_ptr<TargetTraits> &traits :
       TargetTraitsRegistry::get().targets())
    if (!traits->acceleratorSectionTitle().empty())
      targets.push_back(traits.get());
  llvm::sort(targets, [](const TargetTraits *lhs, const TargetTraits *rhs) {
    return lhs->name() < rhs->name();
  });

  llvm::ListSeparator sectionSep("\n");
  for (const TargetTraits *traits : targets) {
    llvm::outs() << sectionSep << traits->acceleratorSectionTitle() << "\n";
    // Pad the arch column so the descriptions line up.
    size_t width = 12;
    for (const TargetTraits::AcceleratorArch &arch :
         traits->supportedAcceleratorArchs())
      width = std::max(width, arch.arch.size() + 2);
    for (const TargetTraits::AcceleratorArch &arch :
         traits->supportedAcceleratorArchs())
      llvm::outs() << "  " << llvm::left_justify(arch.arch, width) << "- "
                   << arch.description << "\n";
  }

  llvm::outs() << "#\n";

  llvm::outs() << "\nUsage: mojo build --target-accelerator <arch> file.mojo\n";

  return EXIT_SUCCESS;
}

/// Print effective target configuration as command-line options.
static int printEffectiveTarget(TargetInfoAttr targetInfo) {
  std::string normalized = normalizeTriple(targetInfo.getTripleStr());
  StringRef cpu = targetInfo.getArch();
  StringRef features = targetInfo.getFeatures();
  StringRef abi = targetInfo.getAbi();
  StringRef accelerator = targetInfo.getAcceleratorArch();

  llvm::outs() << "Effective target configuration:\n";

  llvm::outs() << "  --target-triple " << normalized << "\n";
  llvm::outs() << "  --target-cpu " << cpu << "\n";
  if (!features.empty())
    llvm::outs() << "  --target-features " << features << "\n";
  if (!abi.empty())
    llvm::outs() << "  --target-abi " << abi << "\n";
  if (!accelerator.empty())
    llvm::outs() << "  --target-accelerator " << accelerator << "\n";

  return EXIT_SUCCESS;
}

} // namespace

/// Parses the command line arguments from the given `state` object.
static std::optional<int> parseArgs(State &state, llvm::opt::InputArgList &args,
                                    llvm::SourceMgr &sourceManager,
                                    CompilationOptions &compilationOptions,
                                    MLIRContext &ctx, TargetInfoAttr &target,
                                    BuildOptTable &options) {

  // First, parse arguments to check for help flags.
  // We need to do this separately because help text is command-specific.
  unsigned missingIndex = 0;
  unsigned missingCount = 0;
  llvm::opt::InputArgList allArgs =
      options.ParseArgs(state.arguments, missingIndex, missingCount);

  // Check for help before doing any other processing.
  if (allArgs.hasArg(options::OPT_help)) {
    return state.printHelp(
#include "Build/BuildOptionsHelpText.inc"
    );
  } else if (allArgs.hasArg(options::OPT_help_hidden)) {
    return state.printHelp(
#include "Build/BuildOptionsHelpHiddenText.inc"
    );
  }

  // Check for print target information options. Only one is allowed at a time.
  bool hasPrintEffectiveTarget =
      allArgs.hasArg(options::OPT_print_effective_target);
  bool hasPrintSupportedTargets =
      allArgs.hasArg(options::OPT_print_supported_targets);
  bool hasPrintSupportedCpus =
      allArgs.hasArg(options::OPT_print_supported_cpus);
  bool hasPrintSupportedAccelerators =
      allArgs.hasArg(options::OPT_print_supported_accelerators);

  int printOptionCount = hasPrintEffectiveTarget + hasPrintSupportedTargets +
                         hasPrintSupportedCpus + hasPrintSupportedAccelerators;

  if (printOptionCount > 1) {
    return state.reportError(
        "only one --print-* option can be specified at a time");
  }

  // Track if we have a print option that doesn't require an input file.
  bool hasPrintOption = printOptionCount > 0;

  // Handle --print-supported-targets (simplest, no target parsing needed).
  if (hasPrintSupportedTargets)
    return printSupportedTargets();

  // Handle --print-supported-accelerators (no target parsing needed).
  if (hasPrintSupportedAccelerators)
    return printSupportedAccelerators();

  // Handle --print-supported-cpus (requires --target-triple).
  if (hasPrintSupportedCpus) {
    StringRef userTriple =
        allArgs.getLastArgValue(options::OPT_target_triple, "");
    return printSupportedCpus(userTriple);
  }

  // Set up common option IDs.
  CommonOptionIDs optionIDs{
      .help = options::OPT_help,
      .helpHidden = options::OPT_help_hidden,
      .diagnosticFormat = options::OPT_diagnostic_format,
      .disableWarnings = options::OPT_disable_warnings,
      .warningsAsErrors = options::OPT_werror,
      .noWarningsAsErrors = options::OPT_wno_error,
      .ignoreIncompatiblePrecompiledFileErrors =
          options::OPT_ignore_incompatible_precompiled_file_errors,
      .unknown = options::OPT_UNKNOWN,
      .input = options::OPT_INPUT,
      .includeDirs = options::OPT_I,
      .optimizationLevel = options::OPT_optimization_level,
      .fpMode = options::OPT_fp_mode,
      .debugLevel = options::OPT_debug_level,
      .sanitize = options::OPT_sanitize,
      .sharedLibasan = options::OPT_shared_libasan,
      .externalLibasan = options::OPT_external_libasan,
      .bitcodeLibs = options::OPT_bitcode_libs,
      .debugInfoLanguage = options::OPT_debug_info_language,
      .numThreads = options::OPT_num_threads,
      .mojoSearchPaths = options::OPT_mojo_search_paths,
      .loopUnrollingWarnThreshold = options::OPT_loop_unrolling_warn_threshold,
      .elaborationErrorLimit = options::OPT_elaboration_error_limit,
      .elaborationErrorIncludePrelude =
          options::OPT_elaboration_error_include_prelude,
      .elaborationErrorVerbose = options::OPT_elaboration_error_verbose,
      .elaborationMaxDepth = options::OPT_elaboration_max_depth,
      .targetTriple = options::OPT_target_triple,
      .targetCpu = options::OPT_target_cpu,
      .targetFeatures = options::OPT_target_features,
      .targetAbi = options::OPT_target_abi,
      .march = options::OPT_march,
      .mcpu = options::OPT_mcpu,
      .mtune = options::OPT_mtune,
      .targetAccelerator = options::OPT_target_accelerator,
      .mcmodel = options::OPT_mcmodel,
      .largeDataThreshold = options::OPT_large_data_threshold,
      .relocationModel = options::OPT_relocation_model,
      .diagnoseMissingDocStrings = options::OPT_diagnose_missing_doc_strings,
      .maxNotes = options::OPT_max_notes,
      .defines = options::OPT_D,
      .stripFilePrefix = options::OPT_strip_file_prefix,
      .disableBuiltins = options::OPT_disable_builtins,
      .fixit = options::OPT_fixit,
      .exportFixit = options::OPT_export_fixit,
      .warnOnUnstableAPIs = options::OPT_warn_on_unstable_apis,
      .ignoreDeprecated = options::OPT_ignore_deprecated,
      .lldPath = options::OPT_lld_path,
  };

  // Configure parsing for `mojo build` - parse all arguments normally.
  // For print options, we don't require an input file.
  CommonParseConfig config{
      .parseAllArguments = true,
      .requireSingleInput = !hasPrintOption,
  };

  // Parse common arguments.
  ErrorOr<CommonParseResult> result = parseCommonMojoArguments(
      state, sourceManager, ctx, options, optionIDs, config);
  if (failed(result))
    return state.reportError(result.getError());

  if (result->exitCode)
    return *result->exitCode;

  // Handle print options that require target parsing.
  if (hasPrintEffectiveTarget)
    return printEffectiveTarget(result->target);

  // Extract results.
  args = std::move(result->args);
  compilationOptions = std::move(result->compilationOptions);
  target = std::move(result->target);
  return {};
}

//===----------------------------------------------------------------------===//
// Mojo program execution
//===----------------------------------------------------------------------===//

// What output file type `mojo build` will generate.
enum class OutputType {
  // Produce an executable file containing machine code, e.g. a `.exe` on
  // Windows, or an extensionless binary on Unix-like operating systems.
  //
  // Produced by default or when `--emit exe` is specified.
  executable,
  // Produce a shared (dynamic) library, with the appropriate file extension
  // for the OS (.dylib, .so, or .dll).
  //
  // Produced when `--emit shared-lib` is specified.
  sharedLibrary,
  // Produce an object file(.o) containing machine code.
  //
  // Produced when `--emit object` is specified.
  object,
  // Produce LLVM IR, with the appropriate file extension (.ll).
  //
  // Produced when `--emit llvm` is specified.
  llvm,
  // Produce bitcode of LLVM IR, with the appropriate file extension (.bc).
  //
  // Produced when `--emit llvm` is specified.
  llvmBitcode,
  // Produce assembly code, with the appropriate file extension (.s).
  //
  // Produced when `--emit asm` is specified.
  assembly,
};

/// Return the output file path for a given extension: the value of `-o` if
/// provided, otherwise `<input-stem><fileExtension>`.
static std::string deriveOutputPath(const llvm::opt::InputArgList &args,
                                    StringRef fileExtension) {
  StringRef inputName = args.getLastArgValue(options::OPT_INPUT);
  StringRef inputBaseName = inputName.rsplit('.').first;
  std::string defaultPath = (inputBaseName + fileExtension).str();
  return args.getLastArgValue(options::OPT_o, defaultPath).str();
}

/// Helper function to create an output file with the given extension
static std::unique_ptr<llvm::ToolOutputFile>
createOutputFile(const State &state, const llvm::opt::InputArgList &args,
                 bool hasBinaryOutput, StringRef fileExtension) {
  if (args.getLastArgValue(options::OPT_INPUT).empty()) {
    state.reportError("no input file provided");
    return nullptr;
  }

  std::string outputPath = deriveOutputPath(args, fileExtension);

  std::error_code ec;
  auto outFile = std::make_unique<llvm::ToolOutputFile>(outputPath, ec,
                                                        llvm::sys::fs::OF_None);
  if (ec) {
    state.reportError("could not open output file: " + ec.message());
    return nullptr;
  }

  return outFile;
}

/// Given a module representing a Mojo program, compile the program to a static
/// archive. Returns an unsuccessful exit code if the archive could not be
/// created successfully, and nullopt otherwise.
static std::optional<int> compileModuleToArchive(
    const State &state, AsyncRT::CPUDevice &cpuDevice, MLIRContext &context,
    const CompilationOptions &options, OwningOpRef<ModuleOp> module,
    TargetInfoAttr target, BufferRef &archive, OutputType outputType,
    const llvm::opt::InputArgList &args, PassManagerConfigOptions pmOptions) {
  // For --emit=asm and --emit=llvm, set offloadOutputPrefix so
  // compileOffloads() writes offload kernel files alongside the host output.
  // These two modes are mutually exclusive; offloadOutputKind selects which
  // kind to produce. Must be set before runKGENPipeline().
  CompilationOptions effectiveOptions = options;
  if (outputType == OutputType::assembly || outputType == OutputType::llvm) {
    llvm::StringRef hostExt = outputType == OutputType::llvm ? ".ll" : ".s";
    std::string outPath = deriveOutputPath(args, hostExt);
    llvm::SmallString<256> prefix(outPath);
    llvm::sys::path::replace_extension(prefix, "");
    effectiveOptions.offloadOutputPrefix = prefix.str().str();
    effectiveOptions.offloadOutputKind =
        outputType == OutputType::llvm ? EmitAs::LLVM : EmitAs::ASM;
  }

  KGENCompiler compiler(context, effectiveOptions, pmOptions);

  // Compile the moduleOp down to the post-elaboration phase, because before
  // that phase we don't have flat symbols.
  ErrorOr<std::unique_ptr<ObjectCompiler>> objectCompilerOr =
      ObjectCompiler::create(kMojoCacheBaseDirName, effectiveOptions,
                             /*isJIT=*/false, context, pmOptions);

  if (objectCompilerOr.isError())
    return state.reportError(objectCompilerOr.getError());

  if (ErrorOrSuccess err = compiler.runKGENPipeline(*module, target))
    return state.reportError(err.getError());

  std::unique_ptr<ObjectCompiler> objectCompiler = objectCompilerOr.takeValue();

  // Extract and set bitcode libraries from the module before compilation.
  if (auto arrayAttr =
          module->getOperation()->getAttrOfType<LLVMBitcodeLibArrayAttr>(
              LLVMBitcodeLibArrayAttr::getBitcodeLibsAttrName()))
    arrayAttr.externalize(objectCompiler->getBitcodeLibs());

  // Generate a symbol table and an export map for the module post-compile.
  SymbolTable symtab(*module);
  switch (outputType) {
  case OutputType::object:
    // Objects can be linked as a executable or shared library.
    break;
  case OutputType::executable:
    if (!symtab.lookup("main"))
      return state.reportError("module does not contain a 'main' function");
    break;
  case OutputType::sharedLibrary:
    if (symtab.lookup("main"))
      return state.reportError(
          "shared library should not contain a 'main' function");
    break;
  case OutputType::llvm:
  case OutputType::llvmBitcode: {
    // Compile Module to LLVM IR
    llvm::LLVMContext llvmCtx;
    ErrorOr<std::unique_ptr<llvm::Module>> llvmModuleOr =
        objectCompiler->lowerAllFuncsToLLVM(llvmCtx, *module);
    if (llvmModuleOr.isError())
      return state.reportError(Twine("could not lower funcs to LLVM: ") +
                               llvmModuleOr.getError());

    const std::string fileExtension =
        outputType == OutputType::llvm ? ".ll" : ".bc";
    // Open .ll file
    auto outFile =
        createOutputFile(state, args, /*hasBinaryOutput=*/false, fileExtension);
    if (!outFile)
      return state.reportError("could not open .ll output file");

    // Print to .ll file
    std::unique_ptr<llvm::Module> llvmModule = llvmModuleOr.takeValue();
    if (outputType == OutputType::llvmBitcode) {
      if (ErrorOrSuccess err =
              objectCompiler->emitBitcode(*llvmModule, outFile->os()))
        return state.reportError(err.getError());
    } else {
      llvmModule->print(outFile->os(), nullptr);
    }
    outFile->keep();

    // Return with success to avoid the link step
    return EXIT_SUCCESS;
  } break;
  case OutputType::assembly: {
    // Compile Module to Assembly
    auto outFile =
        createOutputFile(state, args, /*hasBinaryOutput=*/false, ".s");
    if (!outFile)
      return state.reportError("could not open .s output file");

    if (failed(objectCompiler->emitAssembly(std::move(module), outFile->os())))
      return state.reportError("could not emit assembly");
    outFile->keep();
    return EXIT_SUCCESS;
  } break;
  }

  // Generate an archive for the module.
  auto archiveOr = objectCompiler->emitArchive(std::move(module));
  if (failed(archiveOr))
    return state.reportError("failed to produce an archive for the module: " +
                             Twine(archiveOr.getError()));
  archive = std::move(*archiveOr);
  return std::nullopt;
}

//===----------------------------------------------------------------------===//
// Target file naming
//===----------------------------------------------------------------------===//
//
// These three used to be answered by the preprocessor, which meant they were
// answered for the machine running `mojo` rather than for the machine the
// output is for. That is the same answer for a native build and a different
// one for a cross build, so the bug was invisible right up until somebody
// needed it not to be.

/// Return the extension an executable has on `triple`, including the dot, or
/// the empty string on the platforms where executables have no extension.
static StringRef getExecutableExtension(const llvm::Triple &triple) {
  return triple.isOSWindows() ? ".exe" : "";
}

/// Return the extension a static archive has on `triple`, including the dot.
static StringRef getStaticArchiveExtension(const llvm::Triple &triple) {
  return triple.isOSWindows() ? ".lib" : ".a";
}

/// Return the file name a shared library built from `stem` has on `triple`.
/// The missing `lib` prefix on Windows is the part that is easy to forget.
static std::string getSharedLibraryFileName(const llvm::Triple &triple,
                                            StringRef stem) {
  if (triple.isOSWindows())
    return (stem + ".dll").str();
  if (triple.isOSDarwin())
    return ("lib" + stem + ".dylib").str();
  return ("lib" + stem + ".so").str();
}

/// The four CRT import libraries an MSVC style link can name. If the install
/// already names one of these in `system_libs` then it has an opinion, and
/// this file must not add a second one: naming two of them is a link error
/// rather than a preference.
static constexpr const char *kWindowsCRTLibs[] = {"msvcrt.lib", "msvcrtd.lib",
                                                  "libcmt.lib", "libcmtd.lib"};

/// The application manifest embedded in every executable this driver links for
/// Windows. Three settings, and each is the answer to a question the program
/// has no way to answer from the inside.
///
/// `activeCodePage` makes the process code page UTF-8. That is not the console
/// code page, which the standard library sets on the first thing written to a
/// console. This is what the narrow Win32 and C runtime entry points use, and
/// what the command line a program is handed is encoded in, so without it a
/// non ASCII argument arrives mangled according to whatever the machine's
/// locale is and nothing can be done about it later because the damage is done
/// before `main` runs. Windows 10 1903 and later reads it and older versions
/// ignore it and behave as they did.
///
/// `longPathAware` lifts the 260 character path limit for the whole process on
/// a machine where the matching system setting is on. It is not what makes
/// long paths work here: the standard library puts the `\\?\` prefix on paths
/// itself, which works everywhere with nothing configured, and that stays the
/// mechanism. This is for the paths the standard library never sees, meaning
/// whatever the C runtime or a linked in library does with a path of its own.
///
/// `requestedExecutionLevel` at `asInvoker` turns off installer detection,
/// which is a heuristic the loader applies to an executable with no manifest:
/// it reads the file name and the version resource, and on finding something
/// like setup or update or patch in them it asks for elevation. A Mojo program
/// called `update.exe` should not prompt for administrator, and a manifest
/// saying so is the documented way to stop it.
///
/// There is deliberately no `compatibility` section listing supported OS
/// GUIDs. That one changes what `GetVersionEx` reports and which compatibility
/// shims the loader applies, which is a separate decision from the three above
/// and one nothing here needs an answer to yet.
static const char kWindowsManifest[] =
    R"(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <activeCodePage
        xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings"
        >UTF-8</activeCodePage>
      <longPathAware
        xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings"
        >true</longPathAware>
    </windowsSettings>
  </application>
</assembly>
)";

/// Build the bytes of a Windows resource file, the `.res` that `rc.exe`
/// produces, holding `manifest` as its only resource.
///
/// The obvious way to do this is `/manifest:embed` with `/manifestinput:` on
/// the link line, and it does not work. LLD merges a `/manifestinput:` file
/// with the one it generates using the XML support in LLVM, an LLVM built
/// without libxml2 has none, and the fallback is to shell out to `mt.exe`,
/// which fails with a message about not finding it in PATH. The lld that ships
/// alongside this compiler is built without libxml2 and it is the one this
/// driver invokes, so that route is closed. The `lld-link` in the Bazel
/// toolchain does have libxml2 and does merge, which is worth writing down
/// only because it means the failure does not reproduce in the place somebody
/// would look for it first.
///
/// A resource file needs neither piece. Converting one to the `.rsrc` section
/// of an image is in LLVM's object library rather than in its manifest code,
/// and every COFF linker accepts a `.res` as an ordinary input file. So the
/// record gets written here. The format is fixed and small: an empty record,
/// then one record per resource, each a header followed by its data, with
/// everything padded out to four bytes.
static std::string buildWindowsManifestResource(StringRef manifest) {
  // RT_MANIFEST, and the resource id a manifest for the process itself has to
  // use. A DLL would use 2 instead, which is one of the reasons this only goes
  // on executables.
  constexpr uint16_t kResourceTypeManifest = 24;
  constexpr uint16_t kProcessManifestId = 1;
  // US English. Nothing reads the language of a manifest, but it is what
  // rc.exe writes and there is no reason to be the odd one out.
  constexpr uint16_t kLangEnglishUS = 1033;
  // Moveable, pure and discardable, again matching rc.exe. These describe how
  // a 16 bit Windows would have loaded the resource and nothing has read them
  // in thirty years.
  constexpr uint16_t kMemoryFlags = 0x1030;

  // A resource file is little endian whatever the machine writing it is, so
  // the bytes go out one at a time rather than through anything that would
  // pick up the host's order.
  std::string res;
  auto u16 = [&](uint16_t value) {
    res.push_back(static_cast<char>(value & 0xFF));
    res.push_back(static_cast<char>((value >> 8) & 0xFF));
  };
  auto u32 = [&](uint32_t value) {
    u16(static_cast<uint16_t>(value & 0xFFFF));
    u16(static_cast<uint16_t>(value >> 16));
  };
  auto header = [&](uint32_t dataSize, uint16_t type, uint16_t id,
                    uint16_t memoryFlags, uint16_t language) {
    u32(dataSize);
    // The size of this header. Fixed at 32 here because both the type and the
    // name are written as ordinals, which are two words each. Spelling either
    // as a string would make it variable and would need padding of its own.
    u32(32);
    u16(0xFFFF); // An ordinal type follows rather than a name.
    u16(type);
    u16(0xFFFF); // And likewise for the name.
    u16(id);
    u32(0); // Data version, unused.
    u16(memoryFlags);
    u16(language);
    u32(0); // Version, unused.
    u32(0); // Characteristics, unused.
  };

  // Every resource file opens with an empty record. It is how a reader tells
  // this format from the 16 bit one, which has no such thing at the front.
  header(0, 0, 0, 0, 0);

  header(manifest.size(), kResourceTypeManifest, kProcessManifestId,
         kMemoryFlags, kLangEnglishUS);
  res.append(manifest.begin(), manifest.end());
  res.append((4 - (manifest.size() % 4)) % 4, '\0');
  return res;
}

/// Find the linker called `linkerFilename`, looking in the directory lld ships
/// in before falling back to PATH. That order is the whole point when the
/// target is Windows: the linker we want is the one that came with mojo, not
/// whatever the user happens to have installed. `findProgramByName` searches
/// PATH only when it is given no directories of its own, so this is two calls
/// rather than one list.
static llvm::ErrorOr<std::string> findBundledLinker(MojoConfig &config,
                                                    StringRef linkerFilename) {
  SmallString<128> installBin(config.getLLDPath());
  llvm::sys::path::remove_filename(installBin);
  if (!installBin.empty()) {
    StringRef dir = installBin;
    if (llvm::ErrorOr<std::string> found =
            llvm::sys::findProgramByName(linkerFilename, {dir}))
      return found;
  }
  return llvm::sys::findProgramByName(linkerFilename);
}

#if defined(__APPLE__)
/// Generate a dSYM bundle for the given binary in the same directory.
static int generateDSYM(const State &state, StringRef binaryOutputPath) {
  // Resolve the xcrun path.
  llvm::ErrorOr<std::string> xcrun = llvm::sys::findProgramByName("xcrun");
  if (!xcrun)
    return state.reportError("unable to find xcrun");

  std::string errorMsg;
  // Note: this .dSYM bundle is tied to the specific executable generated
  // above via an embedded UUID.
  std::string dsymBundle = (binaryOutputPath + ".dSYM").str();
  SmallVector<StringRef> xcrunArgs = {*xcrun, "dsymutil", binaryOutputPath,
                                      "-o", dsymBundle};
  int xcrunExitCode = llvm::sys::ExecuteAndWait(
      *xcrun, xcrunArgs, /*Env=*/std::nullopt, /*Redirects=*/{},
      /*SecondsToWait=*/0, /*MemoryLimit=*/0, /*ErrMsg=*/&errorMsg);
  if (xcrunExitCode) {
    if (!errorMsg.empty())
      errorMsg.insert(0, ": ");
    return state.reportError("failed to create dSYM bundle" + errorMsg);
  }
  return EXIT_SUCCESS;
}
#endif

/// Given a static archive generated from a mojo module, either
/// 1. Link an executable from that archive.
/// 2. Produce a dynamic library for the Python extension module from that
///    archive.
/// Returns a successful exit code if the executable was linked
/// successfully, otherwise returns a failure code.
static int linkOutput(OutputType outputType, const State &state,
                      const llvm::opt::InputArgList &args,
                      const CompilationOptions &options, BufferRef &archive) {
  // Everything below is decided from the target triple. It used to be decided
  // by `#ifdef _WIN32`, which asks about the machine running the compiler and
  // not the machine the output is for. Two things came of that. Cross
  // compiling picked the host's linker and the host's file extensions, which
  // is simply wrong. And because the Windows arm sat inside a preprocessor
  // branch, it was never compiled on Linux or macOS at all, so it could not
  // be typechecked, let alone run. It is ordinary code now.
  const llvm::Triple triple(options.targetTriple);
  const bool isWindows = triple.isOSWindows();
  const bool isDarwin = triple.isOSDarwin();

  // For now we just use the system C compiler as the linker on non-windows,
  // which makes it a tad bit easier to link in the necessary system and
  // cpuDevice dependencies of KGENCompilerRT.
  //
  // Windows has no equivalent driver to reach for, so it gets the linker
  // itself. lld-link and not link.exe, because link.exe means a user needs a
  // Visual Studio install to compile a Mojo program and the reason this
  // project bundles lld is so that they do not. `linker_driver` in
  // modular.cfg still overrides this, so anybody who runs into an lld bug can
  // point it back at link.exe without rebuilding anything.
  StringRef linkerFilename = isWindows ? "lld-link" : "cc";
  StringRef binaryExt = getExecutableExtension(triple);
  StringRef libExt = getStaticArchiveExtension(triple);

  // Read the mojo configuration.
  ErrorOr<MojoConfig> configOr = MojoConfig::open();
  if (failed(configOr)) {
    return state.reportError(Twine("failed to parse 'modular.cfg': ") +
                             configOr.getError());
  }
  MojoConfig config = std::move(*configOr);

  // Build a default output name based on the input file and the current working
  // directory.
  StringRef inputName = args.getLastArgValue(options::OPT_INPUT);

  // Get the file base name, e.g. `foo` in `dir/foo.mojo`. The directory comes
  // off here rather than after the name has been built, which is a change: it
  // used to be `inputName.rsplit('.').first`, keeping `dir/foo`, and the
  // directory was dropped further down by taking `filename()` of the result.
  // That ordering loses the `lib` prefix a shared library has everywhere except
  // Windows, because `lib` + `dir/foo` + `.so` has the prefix glued to the
  // directory and `filename()` then throws the whole lot away. It only ever
  // showed up when the input was named with a path.
  std::string inputStem =
      std::filesystem::path(inputName.str()).stem().string();
  StringRef inputBaseName = inputStem;

  std::string defaultOutputName = [outputType, inputBaseName, binaryExt,
                                   &triple] {
    switch (outputType) {
    case OutputType::executable:
      return (inputBaseName + binaryExt).str();
    case OutputType::sharedLibrary:
      // Returns `foo.dll`, `libfoo.dylib` or `libfoo.so` for a source file
      // called `foo.mojo`. This used to go through
      // PlatformLibrary::getSharedLibraryName, whose prefix and suffix are
      // baked in as build time defines and so describe the machine that built
      // the compiler. That was TODO(MOCO-1772) and this is it being done.
      return getSharedLibraryFileName(triple, inputBaseName);
    case OutputType::llvm:
      return (inputBaseName + ".ll").str();
    case OutputType::llvmBitcode:
      return (inputBaseName + ".bc").str();
    case OutputType::object:
      return (inputBaseName + ".o").str();
    case OutputType::assembly:
      return (inputBaseName + ".asm").str();
    }
  }();
  // Validate this is a valid filename using the `path` ctor.
  defaultOutputName = std::filesystem::path(defaultOutputName).filename();

  std::error_code ec;
  std::filesystem::path cwd = std::filesystem::current_path(ec);
  if (!ec)
    defaultOutputName = cwd.append(defaultOutputName);

  // Invoke the system linker to link the archive into an executable or produce
  // a dynamic library using the provided output filename argument. The
  // checked linked depends on the target platform.
  StringRef outputName =
      args.getLastArgValue(options::OPT_o, defaultOutputName);

  std::vector<std::string> extraLinkerArgs =
      args.getAllArgValues(options::OPT_Xlinker);

  // Assert that we've parsed all command line arguments.
  state.assertNoUnusedArguments(args);

  // Check that the parent directory of the output exists.
  auto outputDirPath =
      std::filesystem::absolute(outputName.str(), ec).parent_path();
  if (!std::filesystem::exists(outputDirPath, ec) || ec) {
    return state.reportError(
        llvm::formatv("unable to write file. The path '{0}' does not exist.",
                      outputDirPath.string()));
  }

  // Resolve the linker path.
  llvm::ErrorOr<std::string> linker = config.getLinkerDriver().str();
  if (linker->empty()) {
    // Only the Windows target looks in the install directory first. On Unix
    // the linker is a system C compiler by design and there is no reason to
    // prefer something out of our own bin directory that happens to share a
    // name with it.
    linker = isWindows ? findBundledLinker(config, linkerFilename)
                       : llvm::sys::findProgramByName(linkerFilename);
    if (!linker) {
      return state.reportError("unable to find '" + Twine(linkerFilename) +
                               "' for linking");
    }
  }

  if (outputType == OutputType::object) {
    if (llvm::Error err = llvm::writeToOutput(outputName, [&](raw_ostream &os) {
          os << archive->getBuffer();
          return llvm::Error::success();
        })) {
      return state.reportError("unable to write object file: " +
                               llvm::toString(std::move(err)));
    }

    return EXIT_SUCCESS;
  }

  // Write the archive to a temporary file.
  auto archiveFileOr =
      writeTempFile("mojo_archive-%%%%%%%" + libExt, archive->getBuffer());
  if (archiveFileOr.isError()) {
    return state.reportError("unable to write temporary files for linking: " +
                             Twine(archiveFileOr.getError()));
  }
  std::string archivePath = archiveFileOr->getPath().string();

  // A Windows executable gets an application manifest, which means writing a
  // resource file alongside the archive and handing it to the linker as one
  // more input. Executables only. Everything in the manifest is a property of
  // the process, and a DLL is loaded into a process whose properties were
  // settled before it arrived, so a manifest in one is read only for the COM
  // isolation case this has nothing to do with.
  //
  // The TempFile is declared here rather than inside the branch because it
  // deletes the file when it goes out of scope and the link has not happened
  // yet at that point.
  std::optional<TempFile> manifestFile;
  std::string manifestPath;
  if (isWindows && outputType == OutputType::executable) {
    std::string resource = buildWindowsManifestResource(kWindowsManifest);
    auto manifestFileOr = writeTempFile("mojo_manifest-%%%%%%%.res", resource);
    if (manifestFileOr.isError()) {
      return state.reportError(
          "unable to write a temporary manifest resource for linking: " +
          Twine(manifestFileOr.getError()));
    }
    manifestFile.emplace(std::move(*manifestFileOr));
    manifestPath = manifestFile->getPath().string();
  }

  // All three of these have to outlive the linker argument vector, which holds
  // StringRefs into them.
  std::string wholeArchiveArg = "/WHOLEARCHIVE:" + archivePath;
  std::string outputArg = ("/out:" + outputName).str();

  // Resolve the path to the CompilerRT library.
  StringRef compilerRTPath = config.getCompilerRTPath();

  if (!std::filesystem::exists(compilerRTPath.str(), ec) || ec)
    return state.reportError("unable to locate Mojo CompilerRT library");

  // Invoke the linker command.
  SmallVector<StringRef> linkerArgs = [&] {
    if (outputType == OutputType::executable)
      return SmallVector<StringRef>{*linker, archivePath, compilerRTPath};

    // Here, we use `--whole-archive` to force every symbol from the `.a` static
    // archive to be included in the resulting library.  In the generated Python
    // bindings case, the exported function symbols otherwise wouldn't appeared
    // "used" by the linker, and so it would get aggressively removed.

    SmallVector<StringRef> linkerInvocation{*linker};

    if (isWindows) {
      // /DLL is -shared and /WHOLEARCHIVE is --whole-archive. The second one
      // was not here at all before, which is the quiet kind of missing: the
      // library links, nothing references the exported entry points, the
      // linker drops them, and the failure shows up as an import error in
      // Python with no mention of the linker anywhere.
      linkerInvocation.push_back("/DLL");
      linkerInvocation.push_back(wholeArchiveArg);
      linkerInvocation.push_back(archivePath);
    } else if (isDarwin) {
      linkerInvocation.push_back("-shared");
      linkerInvocation.push_back("-Wl,-force_load");
      linkerInvocation.push_back(archivePath);
    } else {
      linkerInvocation.push_back("-shared");
      linkerInvocation.push_back("-Wl,--whole-archive");
      linkerInvocation.push_back(archivePath);
      linkerInvocation.push_back("-Wl,--no-whole-archive");
    }

    linkerInvocation.push_back(compilerRTPath);
    // The output name is added once, further down, for both output types.
    // This used to add it here as well, so a shared library was linked with
    // -o twice. Harmless on a GNU driver, which takes the last one, and not
    // something to reproduce for lld-link, which does not know -o at all.
    return linkerInvocation;
  }();

  // Read the configured system libraries here rather than at the point they
  // get appended, because the Windows CRT choice below has to know whether one
  // of them is already a CRT.
  SmallVector<StringRef> systemLibs;
  config.appendSystemLibraryLinkArgs(systemLibs);

  // Add other shared libs.
  //
  // Windows needs a filter on the way through. When `shared_libs` is not set
  // in the config, MojoConfig makes up `-Xlinker -rpath -Xlinker <libdir>`,
  // and an ELF rpath means nothing to lld-link: it does not know -rpath, so it
  // warns about the flag and then reads the directory that followed it as an
  // input file. Nothing is lost by dropping them, because the PE loader
  // already starts its search in the directory the executable was loaded from.
  // This is the same subtraction the Bazel linker driver does, for the same
  // reason.
  // The namer is the target's, not this host's, because whatever comes back
  // gets linked into the binary being produced. It is the same function that
  // names this build's own shared library output, so the two cannot drift.
  SmallVector<StringRef> sharedLibArgs;
  config.appendSharedLibraryLinkArgs(sharedLibArgs, [&](StringRef stem) {
    return getSharedLibraryFileName(triple, stem);
  });
  for (size_t i = 0, e = sharedLibArgs.size(); i < e; ++i) {
    if (isWindows && sharedLibArgs[i] == "-Xlinker" && i + 1 < e &&
        sharedLibArgs[i + 1] == "-rpath") {
      i += 3;
      continue;
    }
    linkerArgs.emplace_back(sharedLibArgs[i]);
  }

  if (isWindows) {
    linkerArgs.emplace_back(outputArg);
    linkerArgs.emplace_back("/nologo");
    linkerArgs.emplace_back("/SUBSYSTEM:CONSOLE");

    // The manifest resource written further up, as an ordinary input file.
    // Nothing has to be said about what it is: the linker reads the extension,
    // turns the records into the .rsrc section and merges them with whatever
    // other resources came in. Empty for a shared library, where there is no
    // manifest to add.
    if (!manifestPath.empty())
      linkerArgs.emplace_back(manifestPath);

    // Ignore `no object files specified; libraries used` warnings.
    linkerArgs.emplace_back("/IGNORE:4001");

    // Add the right VCRT to match the one used when building KGENCompilerRT.
    // This used to be `#if _DEBUG`, which asks how the compiler itself was
    // built and gets it wrong in the direction that hurts. A debug build of
    // mojo cross compiling to Windows asked for msvcrtd.lib, which is not
    // what the runtime it is linking against was built with, and mixing the
    // two CRTs is the classic Windows link that either fails with duplicate
    // symbols or succeeds and then crashes on the first free. Checked, not
    // guessed at: a Linux -c dbg build of this compiler does define _DEBUG,
    // so that branch was live and wrong rather than dead and wrong.
    //
    // Release CRT by default, and `system_libs` in modular.cfg is where to
    // say otherwise, which is where an install would already be naming any
    // other library it happens to need.
    const bool haveCRT = llvm::any_of(systemLibs, [](StringRef lib) {
      return llvm::any_of(kWindowsCRTLibs, [&](const char *crt) {
        return lib.equals_insensitive(crt);
      });
    });
    if (!haveCRT)
      linkerArgs.emplace_back("msvcrt.lib");

    // Mojo only supports X86_64 COFF right now. That used to be a comment
    // above a hardcoded /machine:X64, and now that the target decides rather
    // than the host it can be a check. An arm64 Windows target fails here
    // with a sentence instead of much later with a pile of relocation errors.
    if (triple.getArch() != llvm::Triple::x86_64) {
      return state.reportError("linking for Windows is only supported for "
                               "x86_64, not '" +
                               Twine(triple.getArchName()) + "'");
    }
    linkerArgs.emplace_back("/machine:X64");

    // Keep the debug information the compiler already produced. Targeting
    // Windows, the object file comes out with .debug$S and .debug$T in it,
    // which is CodeView, and a COFF linker only turns those into a .pdb next
    // to the output if it is asked to. Not asking is not a smaller build: it
    // is the same build with the debug information dropped on the floor at
    // the last step, and there is a lot of it, around 190 kilobytes of
    // CodeView in the object for a program whose code is five.
    //
    // What that costs is everything downstream. A .pdb is the only form
    // Windows reads. The stack trace printed on a fault comes out of dbghelp,
    // which has nothing else to look in, so without one a crash reports
    // addresses and module offsets and no function names at all. Every
    // Windows debugger is in the same position.
    //
    // Gated the same way the dSYM further down is gated, so a build that
    // asked for no debug information does not quietly grow a second file.
    // The linker names it after the output, so `foo.exe` gets `foo.pdb`.
    if (options.debugLevel != CompilationOptions::kNoDebug)
      linkerArgs.emplace_back("/DEBUG");

    // Say so rather than quietly producing a binary with no sanitizer in it.
    // The flags below are clang driver flags and there is no clang driver on
    // this path, and asan on Windows needs its runtime named explicitly
    // anyway, so there is nothing to translate here yet.
    if (options.sanitizers.has(Sanitizers::kAddress) ||
        options.sanitizers.has(Sanitizers::kThread)) {
      return state.reportError(
          "sanitizers are not supported when targeting Windows");
    }
  } else {
    linkerArgs.emplace_back("-o");
    linkerArgs.emplace_back(outputName);

    // Add the necessary sanitizer flags.
    if (options.sanitizers.has(Sanitizers::kAddress)) {
      if (options.externalLibasan.empty()) {
        linkerArgs.emplace_back("-fsanitize=address");
        if (options.sharedLibasan)
          linkerArgs.emplace_back("-shared-libasan");
      } else {
        linkerArgs.emplace_back(options.externalLibasan);
      }
    }
    if (options.sanitizers.has(Sanitizers::kThread))
      linkerArgs.emplace_back("-fsanitize=thread");
  }

  // Apply options for stripping unused code. The Windows arm used to fall
  // through to --gc-sections, which a COFF linker does not understand. That
  // one was quiet too: lld-link warns about an argument it does not know and
  // links anyway, so the stripping just did not happen.
  if (isDarwin)
    linkerArgs.emplace_back("-Wl,-dead_strip");
  else if (isWindows)
    linkerArgs.emplace_back("/OPT:REF");
  else
    linkerArgs.emplace_back("-Wl,--gc-sections");

  // The Mojo standard library calls libm entry points such as `hypot` and
  // `expm1`. A C compiler driver doesn't link libm implicitly the way a C++
  // driver does, so request it here. Apple platforms and Windows keep those
  // entry points in libSystem and the CRT, which are already linked.
  if (!isDarwin && !isWindows)
    linkerArgs.emplace_back("-lm");

  // Add any necessary system libraries, read further up.
  linkerArgs.append(systemLibs.begin(), systemLibs.end());

  // Propagate any user-supplied linker flags. Add these last so they take
  // precedence.
  for (const auto &extraArg : extraLinkerArgs) {
    linkerArgs.emplace_back("-Xlinker");
    linkerArgs.emplace_back(extraArg.c_str());
  }

  // Print linker arguments for debugging
  LLVM_DEBUG({
    for (auto arg : linkerArgs) {
      llvm::errs() << arg << " ";
    }
    llvm::errs() << "\n";
  });

  std::string errorMsg;
  int linkExitCode = llvm::sys::ExecuteAndWait(
      *linker, linkerArgs, /*Env=*/std::nullopt, /*Redirects=*/{},
      /*SecondsToWait=*/0, /*MemoryLimit=*/0, /*ErrMsg=*/&errorMsg);
  if (linkExitCode) {
    if (!errorMsg.empty())
      errorMsg.insert(0, ": ");
    if (outputType == OutputType::executable)
      return state.reportError("failed to link executable" + errorMsg);
    return state.reportError("failed to produce dynamic library" + errorMsg);
  }

#if defined(__APPLE__)
  // On macOS, the debug info needs to be generated at link time using dsymutil.
  // The host guard is because this shells out to xcrun. The target check is
  // because a dSYM bundle is a Mach-O idea, and without it a cross build from
  // a Mac would hand dsymutil a PE file and ask it what it thought.
  if (isDarwin && options.debugLevel != CompilationOptions::kNoDebug) {
    if (int code = generateDSYM(state, outputName))
      return code;
  }
#endif

  return EXIT_SUCCESS;
}

/// Given a path to a Mojo source file, open that file, and compile it to an
/// executable. Returns an integer representing a successful exit code if the
/// source file could be compiled without raising an error, otherwise returns a
/// failure code.
static int build(const State &subcommandState) {
  CompilationOptions options;
  BuildOptTable optTable;

  // Parse arguments.
  State state = subcommandState;
  MLIRContext mlirCtx{MLIRContext::Threading::DISABLED};
  TargetInfoAttr target;
  llvm::opt::InputArgList args;
  llvm::SourceMgr sourceMgr;
  if (std::optional<int> exitCode =
          parseArgs(state, args, sourceMgr, options, mlirCtx, target, optTable))
    return *exitCode;

#ifdef KGEN_ENABLE_PASS_OPTIONS
  const char *cKGENOptions = "KGEN_OPTIONS";
  KGEN::KGENPassCLOptions::registerOptions();
  llvm::cl::ParseCommandLineOptions(0, &cKGENOptions, "", nullptr, nullptr,
                                    cKGENOptions);
#endif // KGEN_ENABLE_PASS_OPTIONS

  warnBuildingForDebugWithDebugBuiltCompiler(state, options.debugLevel);

  // Comes before the CPU device, because the option sets the thread count to
  // one. Comes before the MLIR timing, so that the program deletes it later
  // and the MLIR report is the first report.
  LLVMPassTiming llvmTiming;
  llvmTiming.configure(args, options::OPT_llvm_timing, options);

  AsyncRT::CPUDeviceOptions cpuDeviceOptions;
  configureCPUDeviceOptions(cpuDeviceOptions, options);

  // Create our context (including the cpuDevice).
  ErrorOr<ContextRef> ctxOr = Init::createContext(
      "mojo", Init::Options().withCPUDeviceOptions(cpuDeviceOptions), "build");
  if (ctxOr.isError())
    return state.reportError(ctxOr.getError());
  ContextRef ctx = std::move(*ctxOr);
  registerContext(mlirCtx, ctx);

  StringRef emitFileType =
      args.getLastArgValue(options::OPT_emitted_file_type, "exe");

  OutputType outputType = OutputType::executable;
  if (emitFileType == "exe") {
    // Link an executable from the archive (default).
    outputType = OutputType::executable;
  } else if (emitFileType == "shared-lib") {
    // We have a static archive at this point, go ahead and turn it into a
    // dynamic library.
    outputType = OutputType::sharedLibrary;
  } else if (emitFileType == "llvm") {
    outputType = OutputType::llvm;
  } else if (emitFileType == "llvm-bitcode") {
    outputType = OutputType::llvmBitcode;
  } else if (emitFileType == "object") {
    outputType = OutputType::object;
  } else if (emitFileType == "asm") {
    outputType = OutputType::assembly;
  } else {
    return state.reportError(
        Twine("Unrecognized value for `--emit`. Missing case for: ") +
        emitFileType);
  }

  // Lower the input file to an MLIR module.
  AsyncRT::CPUDevice &cpuDevice = *ctx->get<AsyncRT::CPUDevice>();
  mlir::SourceMgrDiagnosticHandler sourceMgrHandler(sourceMgr, &mlirCtx);
  ScopedMLIRWarningHandler warningHandler(&mlirCtx, options.disableWarnings,
                                          options.warningsAsErrors);

  // The timing shows the parse, the passes, and the code generation. The
  // manager prints the report at the end of this function.
  MLIRPassTiming timing;
  if (ErrorOrSuccess err = timing.configure(args, options::OPT_mlir_timing,
                                            options::OPT_mlir_timing_display))
    return state.reportError(err.getError());

  ErrorOr<OwningOpRef<ModuleOp>> moduleOp = invokeMojoParser(
      state, args, options, &mlirCtx, cpuDevice,
      options::OPT_diagnose_missing_doc_strings, options::OPT_max_notes,
      options::OPT_D, options::OPT_strip_file_prefix,
      options::OPT_disable_builtins, options::OPT_mojo_search_paths,
      options::OPT_fixit, options::OPT_export_fixit, &timing.rootScope(),
      [&](LIT::ParserConfig &parserConfig, mlir::TimingScope &ts) {
        return LIT::importMojoFile(ctx, sourceMgr, parserConfig, ts, nullptr);
      });
  if (failed(moduleOp))
    return state.reportError(moduleOp.getError());

  if (!moduleOp.get()->getOperation()) {
    // Only --experimental-fixit returns a null module (after applying fixes).
    // --experimental-export-fixit continues normal execution after writing
    // YAML.
    assert(args.hasArg(options::OPT_fixit));
    return EXIT_SUCCESS;
  }

  // Compile the module to a static archive.
  BufferRef archive;
  if (std::optional<int> exitCode = compileModuleToArchive(
          state, cpuDevice, mlirCtx, options, moduleOp.takeValue(), target,
          archive, outputType, args, timing.passManagerOptions()))
    return *exitCode;

  // Check if any warnings were promoted to errors via -Werror.
  if (warningHandler.wasErrorEmitted())
    return EXIT_FAILURE;

  return linkOutput(outputType, state, args, options, archive);
}

void M::registerBuildSubcommand(SubcommandRegistry &registry) {
  registry.addCallback("build", build);
}
