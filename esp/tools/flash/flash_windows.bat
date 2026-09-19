@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
cd /d "%~dp0"
title ESP32-C5 BLE 网关固件烧录

set "PYCMD="
where py >nul 2>nul && set "PYCMD=py -3"
if not defined PYCMD (
    where python >nul 2>nul && set "PYCMD=python"
)
if not defined PYCMD (
    echo [错误] 未找到 Python，请安装 Python 3.8 以上版本并勾选 Add Python to PATH
    echo         下载地址: https://www.python.org/downloads/windows/
    pause
    exit /b 1
)

%PYCMD% -c "import esptool" >nul 2>nul
if errorlevel 1 (
    echo [提示] 未检测到 esptool，正在安装...
    %PYCMD% -m pip install --upgrade esptool
)

%PYCMD% "%~dp0flash_windows.py" %*
echo.
pause
