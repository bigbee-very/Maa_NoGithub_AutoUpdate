@echo off
chcp 65001 >nul
title MAA Update
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maa-Increment-Update.ps1" %*
pause
