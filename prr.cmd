@echo off
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0prr.ps1" %*
exit /b %errorlevel%
