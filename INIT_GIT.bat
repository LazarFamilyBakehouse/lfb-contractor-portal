@echo off
echo ============================================
echo   LFB Contractor Portal - One-time Git Init
echo   Run this ONCE to wire this folder to GitHub
echo   (Safe to re-run if it failed previously.)
echo ============================================
echo.

cd /d "%~dp0"

REM Step 1: Make sure git is initialized in this folder
if not exist ".git" (
    echo Initializing git in this folder...
    git init -b main
    if %errorlevel% neq 0 (
        echo ERROR: git init failed. Make sure Git is installed.
        pause
        exit /b 1
    )
) else (
    echo Git already initialized here. Continuing.
)

REM Step 2: Make sure origin remote is set (re-add if missing)
git remote remove origin >nul 2>&1
git remote add origin https://github.com/LazarFamilyBakehouse/lfb-contractor-portal.git

REM Step 3: Configure local git identity
git config user.email "info@lazarfamilybakehouse.com"
git config user.name "Lazar Family Bakehouse"

REM Step 4: Fetch everything from GitHub
echo.
echo Fetching from GitHub...
git fetch origin
if %errorlevel% neq 0 (
    echo.
    echo ERROR: Fetch failed.
    echo Most likely cause: terminal git isn't signed into GitHub yet.
    echo Easiest fix: open GitHub Desktop once - it sets up your credentials -
    echo then re-run this file.
    pause
    exit /b 1
)

REM Step 5: Link local main branch to origin/main (works for unborn HEAD)
echo.
echo Linking local main branch to origin/main...
git checkout -f -B main origin/main
if %errorlevel% neq 0 (
    echo ERROR: Couldn't link to origin/main. See message above.
    pause
    exit /b 1
)

REM Step 6: Set upstream so future pulls/pushes know where to go
git branch --set-upstream-to=origin/main main >nul 2>&1

echo.
echo ============================================
echo   SUCCESS! This folder is now wired to GitHub.
echo.
echo   Your local main branch tracks origin/main.
echo   Your local files (including the new .bat files
echo   I added) appear as untracked - they'll be
echo   committed the first time you push.
echo.
echo   What's next:
echo     - To push changes manually:   double-click PUSH_TO_LIVE.bat
echo     - To set up auto-push:        double-click SETUP_AUTOPUSH.bat
echo     - Or use GitHub Desktop:      File - Add Local Repository - point here
echo ============================================
echo.
pause
