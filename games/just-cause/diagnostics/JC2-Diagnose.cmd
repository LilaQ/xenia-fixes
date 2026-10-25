@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0JC2-Diagnose.ps1"
if errorlevel 1 pause
