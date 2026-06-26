@echo off
echo ============================================
echo   LFB Contractor Portal - Deploying to live site...
echo ============================================
echo.

cd /d "%~dp0"

echo Clearing any stale git locks...
if exist ".git\HEAD.lock" del /f ".git\HEAD.lock"
if exist ".git\index.lock" del /f ".git\index.lock"

echo.
echo Pulling latest changes...
git pull --rebase --autostash
if %errorlevel% neq 0 (
    echo ERROR: Pull failed. Check your internet connection.
    pause
    exit /b 1
)

echo.
echo Staging all changes...
git add -A

echo.
echo Committing...
git commit -m "Portal update - %date% %time%"
rem Note: exit code 1 here just means "nothing to commit" - that is OK

echo.
echo Pushing to GitHub (this makes it live)...
git push origin HEAD:main
set PUSH_RESULT=%errorlevel%

if %PUSH_RESULT% equ 0 (
    echo.
    echo ============================================
    echo   SUCCESS! Changes are live.
    echo   Site: https://contractors.lazarfamilybakehouse.com
    echo   GitHub Pages rebuilds in about 1-2 minutes.
    echo ============================================
) else (
    echo.
    echo ============================================
    echo   ERROR: Push failed.
    echo   Check your internet connection and try again.
    echo ============================================
)

echo.
pause
