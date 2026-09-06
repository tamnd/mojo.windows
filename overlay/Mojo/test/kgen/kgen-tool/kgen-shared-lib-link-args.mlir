// COM: Check that the configured link arguments reach the linker that turns an
// COM: object into a shared library. A COFF image has to resolve everything it
// COM: references at link time, so a Windows shared library needs its search
// COM: paths and its import libraries named, and this is how they get named.
// COM:
// COM: Checking that is awkward, because a link that works looks the same as a
// COM: link that quietly dropped the arguments. So ask for a library that is
// COM: not there and read the complaint: only the linker can produce it, and
// COM: it can only produce it if it was handed the name.

// RUN: not env \
// RUN:   MODULAR_MOJO_MAX_SHARED_OBJECT_LIBS=/defaultlib:not_a_real_lib.lib \
// RUN:   kgen %s --target-triple x86_64-pc-windows-msvc -emit=shared-lib \
// RUN:   -o %t.dll 2>&1 | FileCheck %s

// CHECK: not_a_real_lib.lib

// COM: With nothing configured the same module still links, so the empty case
// COM: does not leave a stray argument on the line.

// RUN: kgen %s --target-triple x86_64-pc-windows-msvc -emit=shared-lib -o %t.dll
// RUN: llvm-objdump -p %t.dll | FileCheck %s --check-prefix=LINKED

// LINKED: file format coff-x86-64

kgen.generator export @exp_i64(%arg: i64) -> i64 {
  kgen.return %arg : i64
}
