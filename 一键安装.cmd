@echo off
chcp 65001 >nul 2>nul
setlocal
cd /d "%~dp0"
title Blockly 可视化编程工作台 - 一键安装

echo.
echo   Blockly 可视化编程工作台 - 离线一键安装
echo   ------------------------------------------------
echo   全部依赖都在本目录，不需要联网。
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*

set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
  echo   [x] 安装脚本退出码 = %RC% ，请把上面的报错整段发给开发者。
) else (
  echo   按任意键关闭本窗口。
)
pause >nul
endlocal
