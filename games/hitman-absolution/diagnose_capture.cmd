@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hitman-Meer-Auswerten.ps1"
exit /b %errorlevel%
