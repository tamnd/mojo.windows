@echo off
rem Lets bazelw be typed at a cmd.exe prompt, where a .ps1 is not something the
rem shell knows how to run. All of the work is in bazelw.ps1.
rem
rem The arguments go across in an environment variable rather than on the
rem command line. bazel/internal/windows-argv.ps1 says why.
setlocal
set "MOJO_BAZELW_ARGV=%*"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bazelw.ps1"
exit /b %ERRORLEVEL%
