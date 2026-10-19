@echo off
rem Rolls everything back, clears every cache, then selects and applies a smart DNS from scratch.
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI-DNS.ps1" -Action Update %*
exit /b %errorlevel%
