@echo off
title MAA Update - 仅版本
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maa-Update.ps1" -SkipResource %*

