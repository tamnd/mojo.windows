##===----------------------------------------------------------------------===##
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
##===----------------------------------------------------------------------===##

# Recovers an argument list from the raw command line a batch file handed over.
#
# Both Windows entry points are a .bat that starts a .ps1, because a .bat is
# what cmd.exe and bazelisk can start and a .ps1 is where the logic can live.
# The obvious way to get the arguments across that hop is
#
#     powershell -File wrapper.ps1 %*
#
# and it drops quoting. -File does not parse its tail with the Windows rules,
# it uses a simpler splitter of its own, and the case it gets wrong is a quote
# that starts partway through a token rather than at the beginning of one. So
#
#     --test_filter="Foo Bar"
#
# arrives as two arguments, --test_filter=Foo and Bar, and bazel reports Bar as
# a target that does not exist. That spelling is not unusual, it is exactly what
# PowerShell itself produces when it passes an argument containing a space on to
# a native program, so calling the .bat from a PowerShell prompt is enough to
# hit it.
#
# What does parse the Windows rules correctly is the function every Windows
# program's startup code uses, CommandLineToArgvW. So the .bat puts its whole
# raw tail in an environment variable, which is a channel with no parsing in it
# at all, and this hands that text to the same function the C runtime would have
# used. Arguments with spaces, quotes, backslashes and dollar signs all come out
# the way they went in. The one thing that still does not survive is a literal
# percent sign, because cmd.exe expands those while reading the batch file and
# nothing downstream can put them back.
#
# The alternative was -Command, which does use the real PowerShell parser and
# would also have made $ORIGIN, in a linker argument, expand to nothing.

Add-Type -Namespace Modular -Name Win32Argv -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
'@

function Get-WindowsArgv($raw) {
  if (-not $raw) { return @() }

  $count = 0
  # The first token of a command line is a program name and is parsed by
  # different rules to everything after it, so a placeholder goes on the front
  # and the loop below starts at one to step over it again.
  $block = [Modular.Win32Argv]::CommandLineToArgvW("bazel " + $raw, [ref] $count)
  if ($block -eq [IntPtr]::Zero) {
    throw "could not parse the command line: $raw"
  }

  try {
    $argv = @()
    for ($i = 1; $i -lt $count; $i++) {
      $entry = [Runtime.InteropServices.Marshal]::ReadIntPtr($block, $i * [IntPtr]::Size)
      $argv += [Runtime.InteropServices.Marshal]::PtrToStringUni($entry)
    }
    # The comma stops PowerShell unrolling a one element array into a bare
    # string on the way out, which would then splat as its characters.
    return ,$argv
  } finally {
    # CommandLineToArgvW allocates with LocalAlloc and FreeHGlobal is LocalFree,
    # whatever its name suggests.
    [void][Runtime.InteropServices.Marshal]::FreeHGlobal($block)
  }
}
