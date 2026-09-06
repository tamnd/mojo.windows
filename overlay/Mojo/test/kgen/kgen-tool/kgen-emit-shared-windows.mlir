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
// EXPORTS: exp_i32

// COM: The generator below takes an i32 and not the f32 the linux and darwin
// COM: versions of this test use, and that is not an arbitrary difference. A
// COM: module that touches floating point references `_fltused`, which lives in
// COM: the CRT, and a COFF image has to resolve every symbol it names at link
// COM: time. There is no COFF equivalent of leaving a symbol for the loader the
// COM: way `-undefined dynamic_lookup` does on MachO, so the f32 version of this
// COM: fails with `undefined symbol: _fltused` until the link gets a CRT import
// COM: library to read. Nothing in the shared object path can paper over that,
// COM: so this test stays inside what actually works today. That is the half of
// COM: #134 that is still open.

kgen.generator export @exp_i32(%arg: i32) -> i32 {
  kgen.return %arg : i32
}
