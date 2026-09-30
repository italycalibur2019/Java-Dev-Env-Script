@echo off
rem ============================================================
rem  JavaDevEnv one-click installer (Windows)
rem  Double-click this file, or run:  install.cmd [options]
rem  All output text is produced by PowerShell (UTF-8 console).
rem ============================================================
setlocal
chcp 65001 >nul 2>&1
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
title JavaDevEnv - Install
set "ARGS=-Action install"
if not "%~1"=="" set "ARGS=%*"
"%PS%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0Setup-JavaDevEnv.ps1" %ARGS%
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (echo [JavaDevEnv] finished with errors, exit code = %RC%) else (echo [JavaDevEnv] done.)
echo %CMDCMDLINE% | find /i " /c " >nul && pause
exit /b %RC%
