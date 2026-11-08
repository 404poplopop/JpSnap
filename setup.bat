@echo off
rem JpSnap setup: installs or updates JpSnap for this Windows user (no admin needed). Run it again to update.
rem Options go to pc\install.ps1, e.g.:  setup.bat -AutoStart No
echo.
echo   JpSnap setup
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc\install.ps1" %*
set code=%errorlevel%
if "%~1"=="" pause
exit /b %code%
