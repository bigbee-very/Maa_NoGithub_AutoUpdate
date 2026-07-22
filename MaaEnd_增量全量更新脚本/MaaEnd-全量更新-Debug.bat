@echo off
chcp 65001 >nul
title MaaEnd Download ^& Overwrite
echo.
echo   Downloading - please wait, do NOT close this window
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MaaEnd-FullUpdate-Download.ps1" %*
echo.
pause
