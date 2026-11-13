@echo off
title Remove Duo Tracker auto-update
schtasks /Delete /TN "Duo Tracker Updater" /F >nul 2>&1
del /q "%LOCALAPPDATA%\DuoTracker\updater.ps1" >nul 2>&1
del /q "%LOCALAPPDATA%\DuoTracker\run-hidden.vbs" >nul 2>&1
echo Automatic updates for Duo Tracker are switched off.
echo The addon itself is still installed. Run "Update Duo Tracker.bat" to update by hand or to switch automatic updates back on.
echo.
pause
