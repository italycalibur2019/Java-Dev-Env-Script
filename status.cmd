@echo off
rem Show current environment status.
setlocal
chcp 65001 >nul 2>&1
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
title JavaDevEnv - Status
set "ARGS=-Action status"
if not "%~1"=="" set "ARGS=%*"
"%PS%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0Setup-JavaDevEnv.ps1" %ARGS%
set "RC=%ERRORLEVEL%"
echo.
echo %CMDCMDLINE% | find /i " /c " >nul && pause
exit /b %RC%
