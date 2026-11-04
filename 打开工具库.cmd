@echo off
cd /d "%~dp0"
pwsh -NoProfile -NonInteractive -File "%~dp0tools\start-site.ps1"
if errorlevel 1 pause
