@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hitman-Meer-Eingaben.ps1"
exit /b %errorlevel%
