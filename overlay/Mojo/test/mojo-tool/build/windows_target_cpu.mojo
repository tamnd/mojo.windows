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
# Check that cross compiling for Windows does not put the build machine's own
# CPU into the binary.
#
# `CompilationOptions::setDefaultCPU` used to decide it was building for the
# machine it was running on by comparing the target architecture against the
# host architecture and nothing else. Windows x86_64 built on Linux x86_64 is
# the same architecture, so it took that branch and wrote the answer from
# `llvm::sys::getHostCPUName()` into the module. On the machine this was found
# on that meant a target CPU of raptorlake, with AVX2, AVX-VNNI, GFNI and SHA
# in the feature list, in an executable whose whole point is that somebody else
# is going to run it. It would fault with an illegal instruction on anything
# older than the build machine, at whichever instruction came first.
#
# The CPU name never reaches the linker, so these read the IR rather than the
# link line. `--emit llvm` gets there without needing a Windows sysroot or a
# working COFF link.
#
# The Windows runs below have to be cross builds for any of it to mean
# anything, which is what the UNSUPPORTED line is for. Run natively on Windows
# the first check would be asking for the opposite of what it asks for here.
#
# ===----------------------------------------------------------------------=== #

# UNSUPPORTED: system-windows

# RUN: %mojo-build --emit llvm --target-triple x86_64-pc-windows-msvc %s -o %t.ll
# RUN: FileCheck %s --check-prefix=WIN --input-file=%t.ll

# No value at all is how LLVM prints a target CPU that was left unset, and
# unset means the triple's own baseline. The features that follow are that
# baseline, which is the original AMD64 instruction set and nothing later.
# WIN: "target-cpu" "target-features"="+cx8,+mmx,+sse,+sse2,+x87"

# Asking for a CPU still gets that CPU, so a conservative default costs one
# flag to opt out of. x86-64-v2 is the baseline this repository builds its own
# Windows binaries at, and docs/building.md says why.
# RUN: %mojo-build --emit llvm --target-triple x86_64-pc-windows-msvc --target-cpu=x86-64-v2 %s -o %t2.ll
# RUN: FileCheck %s --check-prefix=WINV2 --input-file=%t2.ll

# WINV2: "target-cpu"="x86-64-v2"
# WINV2-SAME: +sse4.2

# And the same thing through the GCC spelling, which takes a different route
# through the option handling and lands on a different branch of the code under
# test.
# RUN: %mojo-build --emit llvm --target-triple x86_64-pc-windows-msvc --march=x86-64-v3 %s -o %t3.ll
# RUN: FileCheck %s --check-prefix=WINV3 --input-file=%t3.ll

# WINV3: "target-cpu"="x86-64-v3"
# WINV3-SAME: +avx2

# Building for the machine you are sitting at is the case that is supposed to
# keep picking up the host CPU, and this is the check that the fix above did
# not quietly turn into never using it. Whatever `getHostCPUName` reports is
# fine, the only thing pinned is that there is a name.
# RUN: %mojo-build --emit llvm %s -o %t4.ll
# RUN: FileCheck %s --check-prefix=NATIVE --input-file=%t4.ll

# NATIVE: "target-cpu"="{{.+}}"


def main():
    pass
