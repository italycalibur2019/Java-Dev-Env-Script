@echo off
rem Uninstall / rollback. Data directory is kept by default.
setlocal
chcp 65001 >nul 2>&1
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
title JavaDevEnv - Uninstall
set "ARGS=-Action uninstall"
if not "%~1"=="" set "ARGS=%*"
"%PS%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0Setup-JavaDevEnv.ps1" %ARGS%
set "RC=%ERRORLEVEL%"
echo.
echo %CMDCMDLINE% | find /i " /c " >nul && pause
exit /b %RC%
