@echo off
rem Opens the PTZ window without a console. Uses PowerShell 7 when installed, else Windows PowerShell.
where pwsh >nul 2>nul
if %errorlevel%==0 (
  start "" pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0uvc-ptz.ps1" %*
) else (
  start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0uvc-ptz.ps1" %*
)
