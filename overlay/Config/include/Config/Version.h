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
// Information about the Modular build version.
//
//===----------------------------------------------------------------------===//

#ifndef CONFIG_VERSION_H
#define CONFIG_VERSION_H

namespace M {

struct ProjectVersion final {
  int major;
  int minor;
  int patch;
  const char *label;    // version label like "-rc.1"
  const char *revision; // Truncated Git SHA
  const char *buildType;
};

// Names whoever produced this binary when that is not Modular. Every field is
// the empty string in a normal build and nothing about the output changes, so an
// unmodified build pays nothing for this. A distributor shipping a modified
// build sets the //:downstream_* build settings, and the tools then say plainly
// that the binary is not a Modular release.
struct DownstreamBuild final {
  const char *id;             // who produced it, normally "owner/repo"
  const char *build;          // their own revision, so a report can be traced
  const char *upstreamCommit; // the upstream commit it was built from

  bool isSet() const { return id[0] != '\0'; }
};

DownstreamBuild getDownstreamBuild();

ProjectVersion getMAXVersion();
ProjectVersion getMojoVersion();
const char *getMAXVersionString();
const char *getMojoVersionString();

// TODO: Remove
using ModularVersion = ProjectVersion;
ModularVersion getModularVersion();
const char *getModularVersionString();

} // namespace M

#endif // CONFIG_VERSION_H
