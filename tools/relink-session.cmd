@echo off
chcp 65001 >nul 2>nul
setlocal
echo.
echo ============================================================
echo  Relink the moved conversation into the GitHub daily workspace
echo  Session id: session-45c9d71f-05a3-40b8-89be-269c1f8bd390
echo ============================================================
echo.

rem --- hard check: refuse when DSH Desktop is detectable as running ---
tasklist /FI "IMAGENAME eq DSH Desktop.exe" /NH > "%TEMP%\dsh-relink-probe.txt" 2>nul
find /I "DSH Desktop.exe" < "%TEMP%\dsh-relink-probe.txt" >nul 2>nul
if not errorlevel 1 (
  echo [!] DSH Desktop is still running.
  echo     Quit DSH Desktop COMPLETELY first, then run this file again.
  echo     ^(While DSH runs, its in-memory registry overwrites the change.^)
  echo.
  del "%TEMP%\dsh-relink-probe.txt" >nul 2>nul
  pause
  exit /b 1
)
del "%TEMP%\dsh-relink-probe.txt" >nul 2>nul

echo This script edits DSH's workspace registry at:
echo     %USERPROFILE%\.dsh\storages\workspace.json
echo It backs the file up first and is safe to run twice.
echo.
choice /C YN /N /M "DSH Desktop is COMPLETELY closed - continue? [Y=yes, N=cancel] "
if errorlevel 2 (
  echo.
  echo Cancelled. Nothing was changed.
  pause
  exit /b 1
)
echo.

set ELECTRON_RUN_AS_NODE=1
set DSH_DESKTOP_DEFAULT_PROFILE=desktop
set DSH_HOME=%USERPROFILE%\.dsh
"E:\DSH Desktop\DSH Desktop.exe" --expose-internals "%~dp0relink-session.js"
set RC=%errorlevel%
echo.
if "%RC%"=="0" echo [OK] Start DSH Desktop now - the conversation should be listed under the GitHub daily workspace.
if not "%RC%"=="0" echo [FAIL] Exit code %RC%. Nothing was left half-written; read the messages above.
echo.
pause
