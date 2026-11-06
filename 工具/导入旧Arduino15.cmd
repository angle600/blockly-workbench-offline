@echo off
chcp 65001 >nul 2>nul
setlocal
cd /d "%~dp0"
title 旧 Arduino15 安装包 并入 pkg
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0import-old-arduino15.ps1" %*
endlocal
