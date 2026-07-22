@echo off
chcp 65001 >nul
title MaaEnd Download ^& Overwrite (Beta)
echo.
echo   Downloading beta version - please wait, do NOT close this window
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MaaEnd-FullUpdate-Download.ps1" -Channel beta %*
echo.
pause
