@echo off
chcp 65001 >nul
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Maa-FullAmount-Download.ps1" -Silent %*
