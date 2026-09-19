#!/usr/bin/env bash
# ESP-IDF v6.1 环境激活（bash 版本，供本机 Windows 构建使用）
# 与 C:\Espressif\tools\Microsoft.v6.1.PowerShell_profile.ps1 保持一致
export IDF_TOOLS_PATH="C:/Espressif/tools"
export IDF_PATH="E:/ESPSdk/.espressif/v6.1/esp-idf"
export IDF_PYTHON_ENV_PATH="C:\\Espressif\\tools\\python\\v6.1\\venv"
export ESP_IDF_VERSION="6.1"
export IDF_VERSION="6.1.0"
export ESP_ROM_ELF_DIR="C:/Espressif/tools/esp-rom-elfs/20241011/"
export OPENOCD_SCRIPTS="C:/Espressif/tools/openocd-esp32/v0.12.0-esp32-20260703/openocd-esp32/share/openocd/scripts"
export ESP_CLANG_LIBS_PATH="C:/Espressif/tools/esp-clang-libs/esp-21.1.3_20260408/esp-clang/lib"
export IDF_CCACHE_ENABLE=1

# PATH 必须使用 MSYS 风格路径：Git Bash 会把含冒号的 `C:/...` 条目当成
# 路径列表并错误改写，导致子进程里 cmake / ninja 无法解析
IDF_TOOL_PATH="/c/Espressif/tools/ccache/4.12.1/ccache-4.12.1-windows-x86_64"
IDF_TOOL_PATH="$IDF_TOOL_PATH:/c/Espressif/tools/cmake/4.0.3/bin"
IDF_TOOL_PATH="$IDF_TOOL_PATH:/c/Espressif/tools/esp-clang/esp-21.1.3_20260408/esp-clang/bin"
IDF_TOOL_PATH="$IDF_TOOL_PATH:/c/Espressif/tools/idf-exe/1.0.3"
IDF_TOOL_PATH="$IDF_TOOL_PATH:/c/Espressif/tools/ninja/1.12.1"
IDF_TOOL_PATH="$IDF_TOOL_PATH:/c/Espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/bin"
IDF_TOOL_PATH="$IDF_TOOL_PATH:/c/Espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/riscv32-esp-elf/bin"
IDF_TOOL_PATH="$IDF_TOOL_PATH:/c/Espressif/tools/python/v6.1/venv/Scripts"
export PATH="$IDF_TOOL_PATH:$PATH"

export IDF_PYTHON="C:/Espressif/tools/python/v6.1/venv/Scripts/python.exe"
idf() { "$IDF_PYTHON" "$IDF_PATH/tools/idf.py" "$@"; }
export -f idf
