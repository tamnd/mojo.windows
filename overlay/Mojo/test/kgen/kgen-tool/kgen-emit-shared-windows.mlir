// COM: Check that a Windows target triple produces a real PE/COFF DLL. There is
// COM: no REQUIRES line because none of this depends on the host: lld is one
// COM: binary and `-flavor link` picks the COFF driver from any machine, so a
// COM: regression that goes back to asking the host shows up here as an ELF
// COM: shared object under a COFF check.

// RUN: kgen %s --target-triple x86_64-pc-windows-msvc -emit=shared-lib -o %t.dll
// RUN: llvm-objdump -p %t.dll | FileCheck %s
// RUN: llvm-objdump -h %t.dll | FileCheck %s --check-prefix=SECTIONS
// RUN: llvm-objdump -p %t.dll | FileCheck %s --check-prefix=EXPORTS

// CHECK: file format coff-x86-64
// CHECK: Characteristics
// CHECK: DLL
// CHECK: Magic {{.*}}(PE32+)

// SECTIONS: file format coff-x86-64
// SECTIONS: .text

// COM: A DLL with an empty export table loads and is useless, and that is what
// COM: this produced until the object started marking what it wanted published.
// COM: The generator below is declared `export`, so it is what should come out
// COM: the other end, under the name it was given.

// EXPORTS: Export Table:
// EXPORTS: exp_f32

// COM: The f32 below matches the linux and darwin versions of this test, and it
// COM: is the interesting case rather than an arbitrary one. An object with a
// COM: function that takes or returns a float references `_fltused`, which the
// COM: asm printer emits on its own and which the CRT would normally define. A
// COM: COFF image has to resolve every symbol it names at link time and there
// COM: is no CRT on this link, so this failed with `undefined symbol: _fltused`
// COM: until the shared object link line started mapping the name onto a symbol
// COM: the linker always defines.

kgen.generator export @exp_f32(%arg: f32) -> f32 {
  kgen.return %arg : f32
}
