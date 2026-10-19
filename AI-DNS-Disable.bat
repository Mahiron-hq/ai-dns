@echo off
rem Restores the network settings saved before AI-DNS-Enable.bat and removes all AI-DNS data.
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI-DNS.ps1" -Action Disable %*
exit /b %errorlevel%
