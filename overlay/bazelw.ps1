# Downloads bazelisk and runs it, the Windows counterpart of the bazelw shell
# script next to this file.
#
# PowerShell, and not Python like the toolchain drivers under
# bazel/internal/cc-toolchain/tools. Those run inside the build, where python3
# is already something the host has to provide. This one runs before the build
# exists, on a machine where the only interpreter that is certainly installed is
# this one. Asking somebody to install Python before they can run the script
# whose whole job is to install the build tool is the wrong order, and on a
# stock Windows `python` is the Store stub, which prints nothing useful and
# exits 9009.

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "bazel\internal\windows-argv.ps1")

# Started from bazelw.bat, the arguments are in an environment variable and have
# to be split. Started from a PowerShell prompt, which is the shorter path and
# the one to prefer, $args is already correct and there is nothing to undo.
if ($env:MOJO_BAZELW_ARGV) {
  $argv = Get-WindowsArgv $env:MOJO_BAZELW_ARGV
} else {
  $argv = $args
}

$version = "1.27.0"

# Bazelisk publishes windows-arm64 as well, but nothing else in this repository
# targets it, so naming it here would claim support that has never been built or
# run.
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
  [Console]::Error.WriteLine("error: unsupported platform $env:PROCESSOR_ARCHITECTURE")
  exit 1
}

$platform = "windows-amd64"
$sha = "d4b5e1cea61fcdb0bed60f8868c2e37684221b65feae898d1124482cd39ec89e"

$url = "https://github.com/bazelbuild/bazelisk/releases/download/v$version/bazelisk-$platform.exe"
$executable = Join-Path $PSScriptRoot "build\bazelisk-$version-$platform.exe"

# The shell script tests for the executable bit here. Windows has no such bit
# and reports every file as executable, so existence is the whole test, and the
# checksum below is what actually decides whether the file is usable.
if (-not (Test-Path -LiteralPath $executable)) {
  [Console]::Error.WriteLine("Installing bazelisk...")
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $executable) | Out-Null

  # Windows PowerShell defaults to whatever SecurityProtocol the machine policy
  # says, which on an unpatched install still means TLS 1.0. GitHub has not
  # accepted that for years, and the failure is a connection reset with no
  # mention of TLS in it.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  # -UseBasicParsing keeps this away from the Internet Explorer engine, which is
  # not present on Server Core and is on its way out everywhere else. The
  # progress bar is off because rendering it costs more than the download does.
  $previousProgress = $ProgressPreference
  $ProgressPreference = "SilentlyContinue"
  try {
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $executable
    } catch {
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $executable
    }
  } finally {
    $ProgressPreference = $previousProgress
  }

  $actual = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $sha) {
    [Console]::Error.WriteLine("error: bazelisk sha mismatch")
    Remove-Item -Force -LiteralPath $executable
    exit 1
  }
}

# .bazelversion names a fork of Bazel that BuildBuddy publishes, and that
# release has darwin and linux assets and nothing for Windows, so bazelisk gets
# a 404 and the build stops before it has started. What Windows runs instead is
# the stock Bazel release the fork is built from, which is not a guess: the
# linux asset of buildbuddy-io/5.0.382 answers --version with "bazel 9.2.0".
# So the Windows lane is the same Bazel release as every other lane without
# BuildBuddy's patches on top, which is a smaller difference than either of the
# alternatives, those being asking BuildBuddy to publish a Windows asset or
# building and hosting the fork ourselves. See #243.
#
# The mapping is checked rather than assumed. If the pin moves and .bazelversion
# changes, this stops and asks somebody to measure the new one instead of
# quietly running a Bazel nobody has looked at.
$pinnedFork = "buildbuddy-io/5.0.382"
$stockForPinnedFork = "9.2.0"

if (-not $env:USE_BAZEL_VERSION) {
  $bazelVersionFile = Join-Path $PSScriptRoot ".bazelversion"
  if (Test-Path -LiteralPath $bazelVersionFile) {
    # Only the first line, which is all bazelisk reads. The second line of that
    # file is a bazelbuild commit and nothing in this repository consumes it.
    $requested = "$(Get-Content -LiteralPath $bazelVersionFile -TotalCount 1)".Trim()
    if ($requested -eq $pinnedFork) {
      $env:USE_BAZEL_VERSION = $stockForPinnedFork
      [Console]::Error.WriteLine("note: $requested has no Windows build, using Bazel $stockForPinnedFork instead")
    } elseif ($requested -like "*/*") {
      # Some other fork. It may well publish a Windows asset, and it may well
      # not, and either way nobody has checked what stock release it matches.
      [Console]::Error.WriteLine("error: .bazelversion names $requested, which nobody has checked on Windows")
      [Console]::Error.WriteLine("       run its linux asset with --version, put the answer in bazelw.ps1, and try again")
      exit 1
    }
  }
}

# Set BAZEL to the executable path so the rules_go dependency can reference it.
# Without this, rules_go will likely fail in CI with the following error:
#   exec: "bazel": executable file not found in $PATH
$env:BAZEL = $executable

# PowerShell has no exec, so this holds a process open for the length of the
# build. That is one wrapper process per invocation and it is not worth working
# around, but it does mean Ctrl-C is delivered to this script as well as to
# bazel, which is why there is no trap here trying to be clever about it.
& $executable @argv
exit $LASTEXITCODE
