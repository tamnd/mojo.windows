# The Windows counterpart of tools/bazel.
#
# Bazelisk runs the wrapper for every single bazel invocation, so this has the
# same two jobs the shell script has: refuse a build that has not chosen a
# config, and write build/wrapper.bazelrc, which .bazelrc imports without a
# try, so a missing one is a hard error rather than a default.
#
# Started from tools/bazel.bat rather than being called tools/bazel.ps1.
# tools/bazel.bat says why.
#
# Two blocks of the shell script have no translation here rather than a Windows
# one. The Xcode validation is macOS by definition. The /dev/shm sandbox base
# needs a memory backed filesystem, and Windows has no equivalent to point at,
# so the sandbox stays where Bazel puts it.

$ErrorActionPreference = "Stop"

function Write-LinesTo($path, $lines) {
  # Not Set-Content, which ends every line with CRLF and, if asked for UTF-8 in
  # Windows PowerShell, opens the file with a byte order mark. Bazel reads an rc
  # file a line at a time and treats the mark as part of the first line, which
  # turns the leading comment into something that is not a comment.
  [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n")
}

if ($env:BAZEL_REAL -notlike "*bazelisk*" -and $env:BAZEL_REAL -notlike "*bazel-bin*") {
  [Console]::Error.WriteLine("error: bazel should be run through the .\bazelw.ps1 script at the root of the repo")
  exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "bazel\internal\windows-argv.ps1")

# Started from tools/bazel.bat, which is how bazelisk gets here, the arguments
# are in an environment variable and have to be split. Started by hand, $args is
# already correct.
if ($env:MOJO_BAZEL_ARGV) {
  $argv = Get-WindowsArgv $env:MOJO_BAZEL_ARGV
} else {
  $argv = $args
}

$isBuildTestOrRun = $false
foreach ($arg in $argv) {
  # Any config flag: skip
  if ($arg -like "--*") { continue }
  if ($arg -eq "build" -or $arg -eq "test" -or $arg -eq "run") {
    $isBuildTestOrRun = $true
    break
  }
}

# If doing bazel build/test/run, require a config
if ($isBuildTestOrRun) {
  $hasMojoOrMaxConfig = $false
  foreach ($arg in $argv) {
    if ($arg -eq "--config=prebuilt-mojo" -or $arg -eq "--config=build-mojo") {
      $hasMojoOrMaxConfig = $true
    }
  }

  $localBazelrc = Join-Path $repoRoot "local.bazelrc"
  if (Test-Path -LiteralPath $localBazelrc) {
    if (Select-String -LiteralPath $localBazelrc -Pattern "config=prebuilt-mojo|config=build-mojo" -Quiet) {
      $hasMojoOrMaxConfig = $true
    }
  }

  if (-not $hasMojoOrMaxConfig) {
    Write-Output 'Please add either `--config=prebuilt-mojo` or `--config=build-mojo` to your command line.'
    Write-Output 'Use `--config=build-mojo` if you are modifying the Mojo compiler.'
    Write-Output 'Otherwise, use `--config=prebuilt-mojo`.'
    Write-Output 'You can add `build --config=<your choice>` to a `local.bazelrc` file to have it apply to all Bazel calls.'
    exit 1
  }
}

$bazelrcLines = @("# Generated from tools/bazel, do not edit.")

# USER is a Unix variable and is not set on Windows, so this reads USERNAME
# after GITHUB_ACTOR. The two fall back to the same "unknown" the shell script
# uses, and this line only ever ends up as build metadata on an invocation.
$user = $env:GITHUB_ACTOR
if (-not $user) { $user = $env:USERNAME }
if (-not $user) { $user = "unknown" }
$bazelrcLines += "build --build_metadata=USER=$user"

if (-not $env:GITHUB_REPOSITORY) {
  $bazelrcLines += "build --config=disk-cache"
}

$bazelrcRoot = Join-Path $repoRoot "build"
$logsDir = Join-Path $bazelrcRoot "logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

# Cache resource results
$localResources = Join-Path $bazelrcRoot "local-resources.bazelrc"
if (-not (Test-Path -LiteralPath $localResources)) {
  $detect = Join-Path $repoRoot "bazel\internal\detect_local_resources.ps1"
  $detected = & $detect
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
  # Written only after the detection succeeded. The shell script redirects into
  # the file, which leaves an empty one behind when the detection fails, and an
  # empty one is indistinguishable from a machine with no GPUs the next time
  # this runs.
  Write-LinesTo $localResources $detected
}

$bazelrcLines += "import %workspace%/build/local-resources.bazelrc"

Write-LinesTo (Join-Path $bazelrcRoot "wrapper.bazelrc") $bazelrcLines

$executionLog = Join-Path $logsDir "execution.log"
if (Test-Path -LiteralPath $executionLog) {
  Move-Item -Force -LiteralPath $executionLog -Destination (Join-Path $logsDir "execution-previous.log")
}

# Required for emojis to work in filenames. It does nothing by itself on
# Windows, where the encoding of a filename is a property of the API a program
# calls rather than of the environment, but it is set anyway so that a bazel run
# of a program that does read LANG sees the same value on both platforms.
$env:LANG = "en_US.UTF-8"

& $env:BAZEL_REAL @argv
exit $LASTEXITCODE
