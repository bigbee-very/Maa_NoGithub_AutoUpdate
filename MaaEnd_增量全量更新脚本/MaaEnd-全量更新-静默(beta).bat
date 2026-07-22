@echo off
chcp 65001 >nul
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0MaaEnd-FullUpdate-Download.ps1" -Silent -Channel beta %*
