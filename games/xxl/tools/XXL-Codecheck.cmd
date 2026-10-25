@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0XXL-Codecheck.ps1"
if errorlevel 1 pause
