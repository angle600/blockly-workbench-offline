@echo off
chcp 65001 >nul 2>nul
setlocal
cd /d "%~dp0"
title Blockly 工作台 - 把当前改造收进安装包

echo.
echo   把工作台目录里当前的源码 / 脚本 / 配置重新收进 pkg\payload
echo   （改了 app 代码、加了积木、调了脚本之后跑这个）
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Capture %*

echo.
echo   按任意键关闭本窗口。
pause >nul
endlocal
