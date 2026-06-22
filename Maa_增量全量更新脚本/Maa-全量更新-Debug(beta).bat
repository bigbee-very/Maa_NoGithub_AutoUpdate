@echo off
chcp 65001 >nul
title MAA Download & Overwrite
echo.
echo   Downloading - please wait, do NOT close this window
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maa-FullUpdate-Download.ps1" -Channel beta %*
echo.
pause