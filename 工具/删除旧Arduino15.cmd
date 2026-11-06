@echo off
chcp 65001 >nul 2>nul
setlocal
title 删除旧 Arduino15 数据目录
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0delete-old-arduino15.ps1" %*
endlocal
