@echo off
where pwsh >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it from https://aka.ms/powershell-release
  pause
  exit /b 1
)
pwsh -NoLogo -NoProfile -File "%~dp0infra\deploy.ps1" %*
set "deploy_exit=%errorlevel%"
if not "%deploy_exit%"=="0" echo Deployment failed. Read the error above before retrying.
pause
exit /b %deploy_exit%
