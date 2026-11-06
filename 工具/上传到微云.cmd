@echo off
chcp 65001 >nul 2>nul
setlocal
cd /d "%~dp0"
title 上传 pkg 分卷到微云

echo.
echo   把 pkg\volumes 下的分卷传到微云（并发 3）
echo   ================================================
echo   * 已经在微云上的文件会自动跳过，随时可以 Ctrl+C 中断
echo   * 中断后重新双击本文件即可续跑
echo   * 全程约 1 小时（实测 3 并发 ~180 KB/s）
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0上传到微云.ps1" -SkipExisting %*

echo.
echo   按任意键关闭本窗口。
pause >nul
endlocal
