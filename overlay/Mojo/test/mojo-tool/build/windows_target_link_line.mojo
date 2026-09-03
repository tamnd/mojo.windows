# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
#
# Check that the link line `mojo build` produces is decided by the target triple
# and not by the machine running the compiler. Every run below happens on a
# Linux or macOS host, so a regression that goes back to asking the host shows
# up here as a Unix link line under a Windows check prefix.
#
# The linker is replaced with `/bin/echo` through the `linker_driver` config
# key, so these read the arguments `mojo build` would have passed and never link
# anything. Nothing here needs a Windows sysroot or a working COFF link, which
# is the point: the argument list is testable long before the link is.
#
# That trick needs a Unix host, hence the UNSUPPORTED line. When this suite runs
# on Windows natively there will be no `/bin/echo` to point at and this file
# will need a different way to capture the link line.
#
# ===----------------------------------------------------------------------=== #

# UNSUPPORTED: system-windows

# An executable for Windows. Note the archive extension, which is the piece that
# used to come from `#ifdef _WIN32` and so described the host.
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo %mojo-build --target-triple x86_64-pc-windows-msvc %s -o %t.exe 2>&1 | FileCheck %s --check-prefix=WIN

# WIN: mojo_archive-{{[0-9a-fA-F]+}}.lib
# WIN-SAME: /out:{{[^ ]*}}.exe
# WIN-SAME: /nologo
# WIN-SAME: /SUBSYSTEM:CONSOLE
# WIN-SAME: /IGNORE:4001
# WIN-SAME: msvcrt.lib
# WIN-SAME: /machine:X64
# WIN-SAME: /OPT:REF
# WIN-NOT: --gc-sections
# WIN-NOT: -dead_strip

# The same source for Linux, so that a change to the Windows arm that quietly
# leaks into the common path fails here rather than in somebody else's build.
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo %mojo-build --target-triple x86_64-unknown-linux-gnu %s -o %t.out 2>&1 | FileCheck %s --check-prefix=LINUX

# LINUX: mojo_archive-{{[0-9a-fA-F]+}}.a
# LINUX-SAME: -o {{[^ ]*}}.out
# LINUX-SAME: -Wl,--gc-sections
# LINUX-SAME: -lm
# LINUX-NOT: /machine:X64
# LINUX-NOT: msvcrt.lib

# A shared library for Windows, with no -o so the default name is exercised too.
# A DLL has no `lib` prefix, which is the part that is easy to forget, and
# /WHOLEARCHIVE is the COFF spelling of --whole-archive. The input is a separate
# file because a shared library may not have a `main` and because the default
# output name comes from the input file name.
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo %mojo-build --emit shared-lib --target-triple x86_64-pc-windows-msvc %S/inputs/windows_shared_lib.mojo 2>&1 | FileCheck %s --check-prefix=DLL

# DLL: /DLL
# DLL-SAME: /WHOLEARCHIVE:{{[^ ]*}}mojo_archive-{{[0-9a-fA-F]+}}.lib
# DLL-SAME: /out:{{[^ ]*}}windows_shared_lib.dll
# DLL-NOT: --whole-archive

# The same library for Linux, which is where the `lib` prefix and the .so come
# back. This used to go through a pair of build time defines that described the
# machine that built the compiler rather than the target.
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo %mojo-build --emit shared-lib --target-triple x86_64-unknown-linux-gnu %S/inputs/windows_shared_lib.mojo 2>&1 | FileCheck %s --check-prefix=SO

# SO: -shared
# SO-SAME: -Wl,--whole-archive
# SO-SAME: -o {{[^ ]*}}libwindows_shared_lib.so
# SO-NOT: /DLL

# An ELF rpath means nothing to a COFF linker, and lld-link reads the directory
# that follows -rpath as an input file, so the pair gets dropped for Windows and
# only for Windows. Everything else in shared_libs goes through untouched.
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo MODULAR_MOJO_MAX_SHARED_LIBS=-Xlinker,-rpath,-Xlinker,/nonexistent-rpath-dir,-Xlinker,--verbose %mojo-build --target-triple x86_64-pc-windows-msvc %s -o %t.exe 2>&1 | FileCheck %s --check-prefix=RPATHWIN

# RPATHWIN-NOT: -rpath
# RPATHWIN-NOT: nonexistent-rpath-dir
# RPATHWIN: -Xlinker --verbose

# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo MODULAR_MOJO_MAX_SHARED_LIBS=-Xlinker,-rpath,-Xlinker,/nonexistent-rpath-dir,-Xlinker,--verbose %mojo-build --target-triple x86_64-unknown-linux-gnu %s -o %t.out 2>&1 | FileCheck %s --check-prefix=RPATHLINUX

# RPATHLINUX: -Xlinker -rpath -Xlinker /nonexistent-rpath-dir -Xlinker --verbose

# Naming two CRTs is a link error rather than a preference, so if the install
# already has an opinion in system_libs then this file must not add a second.
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo MODULAR_MOJO_MAX_SYSTEM_LIBS=libcmt.lib %mojo-build --target-triple x86_64-pc-windows-msvc %s -o %t.exe 2>&1 | FileCheck %s --check-prefix=CRT

# CRT-NOT: msvcrt.lib
# CRT: libcmt.lib
# CRT-NOT: msvcrt.lib

# Only x86_64 COFF works today, and saying so here beats a pile of relocation
# errors at the end of a long link.
# RUN: not %mojo-build --target-triple aarch64-pc-windows-msvc %s -o %t3.exe 2>&1 | FileCheck %s --check-prefix=ARM64

# ARM64: error: linking for Windows is only supported for x86_64, not 'aarch64'

# The AsyncRT Mojo bindings are linked into the binary being produced, so their
# file name is a question about the target. The config only puts them on the
# link line when the file is actually there, so plant all three spellings in a
# fake package root and see which one gets picked up. A regression here reads as
# a Linux host handing a `.so` to lld-link.
#
# `package_root` is what `getPath` falls back to when a key is not set, and the
# Bazel test environment sets the paths that matter (compilerrt, lld, import
# path, shared libs) explicitly, so pointing it at a temp directory only affects
# the lookup under test.
#
# Every check below is anchored to that temp directory, because under Bazel the
# configured `shared_libs` already names a `libAsyncRTMojoBindings.so` out of the
# build graph and it lands on the link line whatever the target is. That one
# comes from the test rig rather than from the compiler, so an unanchored check
# would be reading somebody else's answer.
# RUN: rm -rf %t.root && mkdir -p %t.root/lib
# RUN: touch %t.root/lib/AsyncRTMojoBindings.dll %t.root/lib/libAsyncRTMojoBindings.so %t.root/lib/libAsyncRTMojoBindings.dylib
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo MODULAR_MOJO_MAX_PACKAGE_ROOT=%t.root %mojo-build --target-triple x86_64-pc-windows-msvc %s -o %t.exe 2>&1 | FileCheck %s --check-prefix=ARTMBWIN --implicit-check-not=.tmp.root/lib/libAsyncRTMojoBindings

# ARTMBWIN: {{[^ ]*}}.tmp.root/lib/AsyncRTMojoBindings.dll

# The same lookup for Linux, where the `lib` prefix and the `.so` are correct.
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo MODULAR_MOJO_MAX_PACKAGE_ROOT=%t.root %mojo-build --target-triple x86_64-unknown-linux-gnu %s -o %t.out 2>&1 | FileCheck %s --check-prefix=ARTMBLINUX --implicit-check-not=.tmp.root/lib/AsyncRTMojoBindings.dll

# ARTMBLINUX: {{[^ ]*}}.tmp.root/lib/libAsyncRTMojoBindings.so

# An explicit `shared_libs_artmb` still wins, because an install that names the
# file has said where it is and no naming rule should second guess that.
# RUN: env MODULAR_MOJO_MAX_LINKER_DRIVER=/bin/echo MODULAR_MOJO_MAX_PACKAGE_ROOT=%t.root MODULAR_MOJO_MAX_SHARED_LIBS_ARTMB=%t.root/lib/libAsyncRTMojoBindings.dylib %mojo-build --target-triple x86_64-pc-windows-msvc %s -o %t.exe 2>&1 | FileCheck %s --check-prefix=ARTMBOVERRIDE --implicit-check-not=.tmp.root/lib/AsyncRTMojoBindings.dll

# ARTMBOVERRIDE: {{[^ ]*}}.tmp.root/lib/libAsyncRTMojoBindings.dylib

# The sanitizer flags below the Windows branch are clang driver flags and there
# is no clang driver on that path, so ask for one and get told.
# RUN: not %mojo-build --target-triple x86_64-pc-windows-msvc --sanitize=address %s -o %t4.exe 2>&1 | FileCheck %s --check-prefix=SANITIZE

# SANITIZE: error: sanitizers are not supported when targeting Windows


def main():
    pass
