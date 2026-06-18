@echo off
title MAA Update
start "" /MIN powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maa-Update.ps1" %*
exit
