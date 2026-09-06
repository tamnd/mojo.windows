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
// Tests for ASSERT_STREAM
//===----------------------------------------------------------------------===//

#include "Support/AssertStream.h"

#include "gtest/gtest.h"

// Windows has no signals to be killed by, so gtest has no KilledBySignal
// there. An abort() goes through the CRT instead and ends the process with
// exit code 3, which is a thing gtest can match on.
#ifdef _WIN32
#define ABORTED_BY_ASSERT testing::ExitedWithCode(3)
#else
#define ABORTED_BY_ASSERT testing::KilledBySignal(6)
#endif

TEST(Assert, Aborts) {
  EXPECT_EXIT(ASSERT_STREAM(false, << "Error message"), ABORTED_BY_ASSERT,
              "Error message");
}
