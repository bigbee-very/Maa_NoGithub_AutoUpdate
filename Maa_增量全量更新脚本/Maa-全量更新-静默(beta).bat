@echo off
chcp 65001 >nul
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Maa-FullUpdate-Download.ps1" -Channel beta -Silent %*
