@echo off
rem Test copy: an update dry run; every check runs, changes are only logged to tests\manual\logs.
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\AI-DNS.ps1" -Action Update -DryRun -Trace -LogDirectory "%~dp0logs" %*
exit /b %errorlevel%
