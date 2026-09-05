@echo off
rem The entry point bazelisk finds for the wrapper on Windows.
rem
rem Bazelisk looks for tools\bazel first, then tools\bazel.ps1, then
rem tools\bazel.bat. The first is skipped because it wants the executable bit
rem and Windows does not report one. The second is worse than skipped: bazelisk
rem finds it, hands the path to CreateProcess, and CreateProcess cannot start a
rem PowerShell script at all, so the run dies with "not a valid Win32
rem application" before the wrapper has said anything. A .bat is a thing
rem CreateProcess does know how to start. That is why there is no
rem tools\bazel.ps1 in this repository and why the PowerShell half is called
rem bazel-wrapper.ps1, a name bazelisk does not look for.
rem
rem The arguments go across in an environment variable rather than on the
rem command line. bazel/internal/windows-argv.ps1 says why.
setlocal
set "MOJO_BAZEL_ARGV=%*"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bazel-wrapper.ps1"
exit /b %ERRORLEVEL%
