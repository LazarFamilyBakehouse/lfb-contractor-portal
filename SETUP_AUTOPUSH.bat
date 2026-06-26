@echo off
echo ============================================
echo   LFB Contractor Portal - Setting up Auto-Push
echo   (Run this ONCE to install)
echo ============================================
echo.

set SCRIPT=%~dp0autopush_watcher.ps1
set TASKNAME=LFB_Contractor_AutoPush

echo Registering background task...

schtasks /delete /tn "%TASKNAME%" /f >nul 2>&1

schtasks /create /tn "%TASKNAME%" ^
  /tr "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%SCRIPT%\"" ^
  /sc onlogon ^
  /rl highest ^
  /f

if %errorlevel% equ 0 (
    echo.
    echo ============================================
    echo   SUCCESS! Auto-push is installed.
    echo.
    echo   It will run automatically every time
    echo   you log in to Windows.
    echo.
    echo   Starting it now for this session...
    echo ============================================
    powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SCRIPT%"
) else (
    echo.
    echo ERROR: Setup failed. Try running as Administrator.
    echo Right-click SETUP_AUTOPUSH.bat and choose
    echo "Run as administrator"
)

pause
