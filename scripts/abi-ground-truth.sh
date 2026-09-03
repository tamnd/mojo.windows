#!/usr/bin/env bash
# Prints what clang actually does with a table of C signatures, for the Windows x64
# convention and for System V side by side.
#
# This exists because the expectations in Mojo/test/kgen/pop-to-llvm/extern-c-abi-win64.mlir
# have to come from somewhere better than a reading of the Microsoft documentation. The ABI
# is the one part of this port that fails silently, so an expectation that is merely
# plausible is worse than no expectation at all. Every line in that test was taken from the
# output of this script.
#
# Run it whenever a case is added, whenever a case is disputed, and whenever clang is
# upgraded. It needs nothing but a clang that can name the two triples, which any clang can
# do because emitting IR needs no headers and no sysroot.
#
# Usage:
#   scripts/abi-ground-truth.sh              # both targets, side by side
#   scripts/abi-ground-truth.sh windows      # just the Windows column
#   scripts/abi-ground-truth.sh linux        # just the System V column

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need clang

WHICH="${1:-both}"

# A directory rather than a bare temp file, because clang decides the language from the
# extension and BSD mktemp will not give a file one.
TMPDIR_ABI="$(mktemp -d)"
SRC="$TMPDIR_ABI/reference.c"
trap 'rm -rf "$TMPDIR_ABI"' EXIT

# The table. Each group here lines up with a group in extern-c-abi-win64.mlir, and the
# names match so a disagreement can be traced back in one step. Anything added to the test
# should be added here first, not the other way round.
cat > "$SRC" <<'EOF'
// Group W: aggregates by size.
typedef struct { char a; } W1;
typedef struct { char a, b; } W2;
typedef struct { char a, b, c; } W3;
typedef struct { int a; } W4;
typedef struct { char a[5]; } W5;
typedef struct { char a[6]; } W6;
typedef struct { char a[7]; } W7;
typedef struct { int a, b; } W8;
typedef struct { int a, b, c; } W9;
typedef struct { long long a, b; } W10;
typedef struct { long long a, b, c; } W11;

// Group X: floats inside aggregates.
typedef struct { float a; } X1;
typedef struct { double a; } X2;
typedef struct { float a, b; } X3;
typedef struct { double a, b; } X4;
typedef struct { int a; float b; } X5;

// Group Y: vectors, nesting and padding.
typedef float V2 __attribute__((vector_size(8)));
typedef float V4 __attribute__((vector_size(16)));
typedef struct { V2 v; } Y3;
typedef struct { V4 v; } Y4;
typedef struct { struct { int a, b; } inner; } Y5;
typedef struct { char a; char b[9]; } Y6;
typedef struct { long long a; char b; } Y7;

void w1(W1 v); void w2(W2 v); void w3(W3 v); void w4(W4 v); void w5(W5 v);
void w6(W6 v); void w7(W7 v); void w8(W8 v); void w9(W9 v); void w10(W10 v);
void w11(W11 v);
void x1(X1 v); void x2(X2 v); void x3(X3 v); void x4(X4 v); void x5(X5 v);
void y1(V2 v); void y2(V4 v); void y3(Y3 v); void y4(Y4 v); void y5(Y5 v);
void y6(Y6 v); void y7(Y7 v);

W1 z1(void); W3 z2(void); W4 z3(void); X1 z4(void); W8 z5(void);
W9 z6(void); X4 z7(void); W11 z8(void);

void s1(int a, float b, double c, void *d);
void v1(int fixed, ...);
void v2(int fixed, ...);

void reference(void) {
  W1 a1={0}; W2 a2={0}; W3 a3={0}; W4 a4={0}; W5 a5={0}; W6 a6={0}; W7 a7={0};
  W8 a8={0}; W9 a9={0}; W10 a10={0}; W11 a11={0};
  X1 b1={0}; X2 b2={0}; X3 b3={0}; X4 b4={0}; X5 b5={0};
  V2 c1={0}; V4 c2={0}; Y3 c3={0}; Y4 c4={0}; Y5 c5={0}; Y6 c6={0}; Y7 c7={0};
  w1(a1); w2(a2); w3(a3); w4(a4); w5(a5); w6(a6); w7(a7); w8(a8); w9(a9);
  w10(a10); w11(a11);
  x1(b1); x2(b2); x3(b3); x4(b4); x5(b5);
  y1(c1); y2(c2); y3(c3); y4(c4); y5(c5); y6(c6); y7(c7);
  z1(); z2(); z3(); z4(); z5(); z6(); z7(); z8();
  s1(0, 0, 0, 0);
  v1(0, 1.0);
  v2(0, a11);
}
EOF

# Only the declarations matter. The attribute group suffix and the `dso_local` that the
# Windows target adds to everything are noise for this purpose, so they come off, which
# also makes the two columns line up when they agree.
emit() {
  local triple="$1"
  clang --target="$triple" -S -emit-llvm -O0 -o - "$SRC" 2>/dev/null \
    | grep '^declare' \
    | grep -v '@llvm\.' \
    | sed -e 's/ #[0-9]*$//' -e 's/^declare dso_local /declare /'
}

if [ "$WHICH" = windows ] || [ "$WHICH" = both ]; then
  info "x86_64-pc-windows-msvc, the Microsoft x64 convention"
  emit x86_64-pc-windows-msvc
fi

if [ "$WHICH" = both ]; then
  printf '\n'
fi

if [ "$WHICH" = linux ] || [ "$WHICH" = both ]; then
  info "x86_64-unknown-linux-gnu, System V, for comparison"
  emit x86_64-unknown-linux-gnu
fi

if [ "$WHICH" != windows ] && [ "$WHICH" != linux ] && [ "$WHICH" != both ]; then
  die "unknown target '$WHICH', expected windows, linux or both"
fi
