@echo off
title MAA Update - 全部
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Maa-Update.ps1" %*
