@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0JC2-JIT-Nachlesen.ps1"
if errorlevel 1 pause
