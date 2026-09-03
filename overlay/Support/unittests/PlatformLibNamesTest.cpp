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
//
// PlatformLibrary is the one place that answers what a library file is called on
// the platform this was built for, and the answer arrives as four defines that
// bazel/config.bzl picks with a select() on @platforms//os. Nothing checked that
// the select and the compiler agreed about which platform that is, and a
// disagreement there is silent: the build succeeds and the name is wrong, and
// the first sign of it is a dlopen that finds nothing.
//
// So the point of the checks below is not that ".so" is spelled ".so". It is
// that the OS Bazel selected on and the OS the compiler is compiling for are the
// same OS.
//
//===----------------------------------------------------------------------===//

#include "Support/PlatformLibNames.h"

#include "gtest/gtest.h"

using namespace M;

TEST(PlatformLibNamesTest, SharedLibraryName) {
#if defined(_WIN32)
  EXPECT_EQ(PlatformLibrary::getSharedLibraryName("MGPRT"), "MGPRT.dll");
#elif defined(__APPLE__)
  EXPECT_EQ(PlatformLibrary::getSharedLibraryName("MGPRT"), "libMGPRT.dylib");
#else
  EXPECT_EQ(PlatformLibrary::getSharedLibraryName("MGPRT"), "libMGPRT.so");
#endif
}

TEST(PlatformLibNamesTest, StaticLibraryName) {
#if defined(_WIN32)
  EXPECT_EQ(PlatformLibrary::getStaticLibraryName("MGPRT"), "MGPRT.lib");
#else
  EXPECT_EQ(PlatformLibrary::getStaticLibraryName("MGPRT"), "libMGPRT.a");
#endif
}

// The prefix and the suffix are not independent. A build that picks the suffix
// per OS and leaves the prefix alone produces `libfoo.dll`, which is a plausible
// looking name that nothing on a Windows system is actually called, and which
// only fails at the point something tries to load it. This is the assertion that
// would have caught that, so it is written as the relationship rather than as
// two more literal comparisons.
TEST(PlatformLibNamesTest, PrefixAndSuffixComeFromTheSameOS) {
  const std::string shared = PlatformLibrary::getSharedLibraryName("foo");
  const bool hasLibPrefix = shared.starts_with("lib");
  const bool isPE = shared.ends_with(".dll");
  EXPECT_NE(hasLibPrefix, isPE);

  const std::string staticLib = PlatformLibrary::getStaticLibraryName("foo");
  EXPECT_EQ(staticLib.starts_with("lib"), hasLibPrefix);
}

// Callers pass a bare stem and expect it back untouched, dots included, because
// several of the names in the runfile mapping table are not plain identifiers.
TEST(PlatformLibNamesTest, StemIsUsedVerbatim) {
  const std::string shared = PlatformLibrary::getSharedLibraryName("Mojo.LLDB");
  EXPECT_NE(shared.find("Mojo.LLDB"), std::string::npos);
}
