@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"

if not exist "%~dp0main.ps1" (
  echo ERROR: main.ps1 not found.
  echo   Expected: %~dp0main.ps1
  echo.
  pause
  exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights ^(UAC^)...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0main.ps1'"
  exit /b 0
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0main.ps1" %*
set "EC=!ERRORLEVEL!"
if !EC! neq 0 (
  echo.
  echo Script exited with error code !EC!.
  pause
  exit /b !EC!
)
exit /b 0
