@echo off
rem Opens the settings menu: service modes, own domains, default switches and what Enable may change.
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI-DNS.ps1" -Action Settings %*
exit /b %errorlevel%
