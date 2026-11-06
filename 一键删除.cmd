@echo off
chcp 65001 >nul 2>nul
setlocal
cd /d "%~dp0"
title Blockly 可视化编程工作台 - 卸载 / 清理

echo.
echo   Blockly 可视化编程工作台 - 卸载 / 清理
echo   ================================================
echo   这个脚本会先列出「要删什么、多大、在哪」，
echo   要你亲手输入 YES 才会真的删。
echo.
echo   只回收空间、不卸载工作台：在本文件上右键 -> 编辑，
echo   把最后一行 powershell 那句后面加上  -CleanPkgOnly
echo   ================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*

set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
  echo   [x] 卸载脚本退出码 = %RC%
  echo       如果提示「删不掉」，多半是工作台或 Arduino IDE 还开着，
  echo       关掉之后重新双击本文件即可。
) else (
  echo   按任意键关闭本窗口。
)
pause >nul
endlocal
