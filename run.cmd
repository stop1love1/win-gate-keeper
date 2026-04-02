@echo off
setlocal EnableDelayedExpansion
if /i "%~1"=="--wgk-install-ps" goto :wgk_install_ps

cd /d "%~dp0"

if not exist "%~dp0main.ps1" (
  echo ERROR: main.ps1 not found.
  echo   Expected: %~dp0main.ps1
  echo.
  pause
  exit /b 1
)

call :ResolvePowerShell
if not defined PS_EXE (
  echo.
  echo WinGateKeeper requires PowerShell. It was not found on this PC.
  echo.
  net session >nul 2>&1
  if errorlevel 1 (
    echo You will be asked to approve Administrator access to install PowerShell.
    call :WgkElevateInstallPs
    exit /b 0
  )
  call :WgkInstallPowerShell
  call :ResolvePowerShell
  if not defined PS_EXE goto :WgkPsInstallFailed
)

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights ^(UAC^)...
  "!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '!PS_EXE!' -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0main.ps1'"
  exit /b 0
)

"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0main.ps1" %*
set "EC=!ERRORLEVEL!"
if !EC! neq 0 (
  echo.
  echo Script exited with error code !EC!.
  pause
  exit /b !EC!
)
exit /b 0

:wgk_install_ps
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  echo ERROR: PowerShell setup must run as Administrator.
  echo Right-click run.cmd and choose "Run as administrator".
  echo.
  pause
  exit /b 1
)
call :WgkInstallPowerShell
call :ResolvePowerShell
if not defined PS_EXE (
  echo.
  echo Automatic PowerShell installation failed.
  echo Install manually from: https://aka.ms/powershell
  echo.
  pause
  exit /b 1
)
echo.
echo PowerShell is ready. Starting WinGateKeeper...
call "%~f0"
set "EC=!ERRORLEVEL!"
exit /b !EC!

:ResolvePowerShell
set "PS_EXE="
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
  set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
  exit /b 0
)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  set "PS_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
  exit /b 0
)
if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" (
  set "PS_EXE=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
  exit /b 0
)
exit /b 0

:WgkInstallPowerShell
echo Installing PowerShell ^(this may take a few minutes^)...
where winget >nul 2>&1
if not errorlevel 1 (
  winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements --silent
  if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" exit /b 0
  if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" exit /b 0
  echo winget finished but pwsh.exe was not found. Trying DISM...
) else (
  echo winget was not found. Trying DISM optional feature...
)
dism /online /enable-feature /featurename:MicrosoftWindowsPowerShellRoot /all /norestart >nul 2>&1
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" exit /b 0
dism /online /enable-feature /featurename:MicrosoftWindowsPowerShell /all /norestart >nul 2>&1
exit /b 0

:WgkElevateInstallPs
set "_V=%TEMP%\wgk_elev_install_ps.vbs"
> "%_V%" (
  echo Set UAC = CreateObject^("Shell.Application"^)
  echo UAC.ShellExecute "cmd.exe", "/c pushd ""%~dp0"" ^&^& ""%~f0"" --wgk-install-ps", "", "runas", 1
)
cscript //nologo "%_V%"
del "%_V%" 2>nul
exit /b 0

:WgkPsInstallFailed
echo.
echo Could not install PowerShell automatically.
echo Install it manually from: https://aka.ms/powershell
echo Then run run.cmd again.
echo.
pause
exit /b 1
