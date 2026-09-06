// COM: The end of the story the other two shared library link tests start.
// COM: They check that arguments reach the linker by naming things that are not
// COM: there; this one names things that are, and links a module that calls
// COM: something it does not define. That is the case a Windows shared library
// COM: could not do at all until the link line learned about libraries, because
// COM: COFF has to resolve every symbol at link time and cannot leave one for
// COM: the loader the way ELF and Mach-O can.
// COM:
// COM: It needs a real Windows CRT and SDK, which cannot be redistributed and
// COM: so is only on a machine somebody put one on. Hence the feature, and
// COM: hence the `--test_env=MOJO_WINDOWS_SYSROOT=...` on the command line that
// COM: runs it, which is written down in docs/building.md. Everywhere else it
// COM: is reported as unsupported.

// REQUIRES: windows-sysroot

// COM: Without the libraries this fails, and it fails on the symbol rather than
// COM: on anything else, which is what says the module really does reach
// COM: outside itself. Worth keeping next to the case below, because a test
// COM: that only showed the working link would still pass if the module quietly
// COM: stopped needing anything.

// RUN: not kgen %s --target-triple x86_64-pc-windows-msvc -emit=shared-lib \
// RUN:   -o %t.dll 2>&1 | FileCheck %s --check-prefix=UNDEFINED

// UNDEFINED: undefined symbol: puts

// COM: With them it links. The shape of the value is what an install would put
// COM: in its configuration: the search paths for the CRT and the UCRT, then
// COM: the import libraries to look in.

// RUN: env \
// RUN:   MODULAR_MOJO_MAX_SHARED_OBJECT_LIBS=/libpath:%windows-sysroot/crt/lib/x86_64,/libpath:%windows-sysroot/sdk/lib/ucrt/x86_64,/defaultlib:msvcrt.lib,/defaultlib:ucrt.lib \
// RUN:   kgen %s --target-triple x86_64-pc-windows-msvc -emit=shared-lib \
// RUN:   -o %t.dll
// RUN: llvm-objdump -p %t.dll | FileCheck %s --check-prefix=LINKED

// COM: `puts` arriving as an import is the point. It is not in the image, it is
// COM: a name the loader fills in from a DLL at load time, and the import
// COM: library on the link line is what turned the call into that. The UCRT is
// COM: split across api set DLLs, so the name is not one anybody would guess.

// LINKED: file format coff-x86-64
// LINKED: DLL Name: api-ms-win-crt-stdio-l1-1-0.dll
// LINKED: puts

llvm.func @puts(!llvm.ptr) -> i32

kgen.generator export @exp_say(%msg: !llvm.ptr) -> i32 {
  %r = llvm.call @puts(%msg) : (!llvm.ptr) -> i32
  kgen.return %r : i32
}
