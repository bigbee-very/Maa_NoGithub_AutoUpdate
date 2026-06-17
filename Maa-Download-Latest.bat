@echo off
chcp 65001 >nul
title MAA Latest Downloader
echo.
echo   Downloading - please wait, do NOT close this window
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maa-Download-Latest.ps1" %*
echo.
pause
