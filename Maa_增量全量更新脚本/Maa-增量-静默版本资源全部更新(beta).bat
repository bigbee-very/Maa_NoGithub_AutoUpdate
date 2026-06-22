@echo off
title MAA Update
start "" /MIN powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maa-Increment-Update.ps1" -Channel beta %*
exit