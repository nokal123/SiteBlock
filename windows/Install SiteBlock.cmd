@echo off
rem Double-click this file to install SiteBlock on this PC, or right-click it and choose "Run as administrator".
rem   1. When it does not have administrator rights yet, it asks Windows for them (the "Do you want to allow this
rem      app to make changes to your device?" prompt) and starts again in a new window that has them.
rem   2. It removes the "downloaded from the internet" mark from the files in its folder.
rem   3. It runs scripts\install.ps1, then scripts\verify-install.ps1, and waits for a key press so the results
rem      can be read.
rem The same file works in two places. Inside the package from GitHub, the programs are ready in bin\. In the
rem repository (where SiteBlock.sln sits next to this file), it first builds the programs with scripts\build.ps1,
rem which needs the .NET 10 SDK.
setlocal
cd /d "%~dp0"

rem The first argument says whether this copy was started again by the part below: --elevated, or --elevated-built
rem when the programs were already built before asking for administrator rights.
set "SB_ARG=%~1"

rem fltmc only works with administrator rights, so its exit code tells whether this window has them.
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if errorlevel 1 goto :not_elevated
goto :elevated

:not_elevated
rem A copy that was already started again and still has no rights must not ask a second time.
if /i "%SB_ARG%"=="--elevated" goto :no_rights
if /i "%SB_ARG%"=="--elevated-built" goto :no_rights
set "SB_NEXT=--elevated"
if not exist "%~dp0SiteBlock.sln" goto :ask_for_rights
rem In the repository the build runs first, as the signed-in user, so the build files belong to that user.
call :build
if errorlevel 1 goto :end_fail
set "SB_NEXT=--elevated-built"

:ask_for_rights
echo Asking Windows for administrator rights...
rem The path goes through an environment variable, so a folder name with an apostrophe or a space cannot break the command.
set "SB_SELF=%~f0"
powershell -NoProfile -Command "Start-Process -FilePath $env:SB_SELF -ArgumentList $env:SB_NEXT -Verb RunAs"
if errorlevel 1 goto :no_rights
rem The new window does the install; this one is done.
exit /b 0

:elevated
echo === Step 1 of 3: preparing the SiteBlock folder ===
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Recurse | Unblock-File"
if not exist "%~dp0SiteBlock.sln" goto :install
if /i "%SB_ARG%"=="--elevated-built" goto :install
call :build
if errorlevel 1 goto :end_fail

:install
echo.
echo === Step 2 of 3: installing SiteBlock ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1"
if errorlevel 1 goto :install_failed

echo.
echo === Step 3 of 3: checking the installation ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\verify-install.ps1"
if errorlevel 1 goto :verify_failed

echo.
echo SiteBlock is installed and running. Click the shield icon by the clock to block your first site;
echo it asks you to choose your SiteBlock password then.
echo.
pause
exit /b 0

:verify_failed
echo.
echo SiteBlock is installed, but at least one check failed. Read the FAIL lines above.
goto :end_fail

:install_failed
echo.
echo The install failed. Read the messages above. It is safe to run this file again.
goto :end_fail

:no_rights
echo.
echo SiteBlock needs administrator rights to install, and Windows did not give them.
echo Right-click "Install SiteBlock.cmd", choose "Run as administrator", and answer Yes.
goto :end_fail

:end_fail
echo.
pause
exit /b 1

rem Builds the programs from the source code with scripts\build.ps1. Sets exit code 1 when the build fails.
:build
echo === Building SiteBlock from the source code: this needs the .NET 10 SDK and takes a few minutes ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build.ps1"
if errorlevel 1 goto :build_failed
exit /b 0

:build_failed
echo.
echo The build failed, so nothing was installed. Read the messages above.
exit /b 1
