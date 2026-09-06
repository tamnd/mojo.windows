// COM: The Mojo runtime's import library goes on a Windows shared object link
// COM: line without anybody naming it, found next to the rest of the compiler's
// COM: own files. There is no install here to find one in, so override where it
// COM: looks and point it at a file that exists and is not a library, which is
// COM: this test. The linker then complains about it, and it can only complain
// COM: about a name it was handed.

// RUN: not env \
// RUN:   MODULAR_MOJO_MAX_COMPILERRT_IMPORT_LIB_PATH=%s \
// RUN:   kgen %s --target-triple x86_64-pc-windows-msvc -emit=shared-lib \
// RUN:   -o %t.dll 2>&1 | FileCheck %s

// CHECK: kgen-shared-lib-runtime-import-lib.mlir

// COM: A path to nothing is passed over rather than named. A compiler running
// COM: on a host that has no Windows runtime installed still has to be able to
// COM: link a module that never wanted one, and it would not be able to if a
// COM: missing file turned into a linker error.

// RUN: env \
// RUN:   MODULAR_MOJO_MAX_COMPILERRT_IMPORT_LIB_PATH=%t-no-such-file.lib \
// RUN:   kgen %s --target-triple x86_64-pc-windows-msvc -emit=shared-lib \
// RUN:   -o %t.dll
// RUN: llvm-objdump -p %t.dll | FileCheck %s --check-prefix=LINKED

// LINKED: file format coff-x86-64

kgen.generator export @exp_i64(%arg: i64) -> i64 {
  kgen.return %arg : i64
}
