@echo off
title MAA Update
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maa-Update.ps1" %*
