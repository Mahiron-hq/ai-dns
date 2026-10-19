@echo off
rem Finds a working smart DNS for ChatGPT, Claude and Gemini and applies it.
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI-DNS.ps1" -Action Enable %*
exit /b %errorlevel%
