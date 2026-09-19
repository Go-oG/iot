#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ESP32-C5 BLE 网关合并固件烧录脚本

默认先整片擦除再写入合并固件，烧录后网关恢复出厂状态，需要重新配网并重新登记设备。

用法:
    python flash_windows.py                自动查找串口并烧录
    python flash_windows.py --list         只列出当前可用串口
    python flash_windows.py --port COM5    指定串口烧录
    python flash_windows.py --keep-flash   不整片擦除，直接覆盖写入
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

FIRMWARE_NAME = "firmware_merged.bin"
CHIP = "esp32c5"
DEFAULT_BAUD = "460800"
FLASH_ARGS = ["--flash-mode", "dio", "--flash-freq", "80m", "--flash-size", "32MB"]
MIN_ESPTOOL = (4, 8)
PORT_HINTS = ("cp210", "ch34", "ch91", "usb", "jtag", "serial", "wch", "ftdi")


class Fail(Exception):
    """带用户提示的失败"""


def esptool(args):
    return [sys.executable, "-m", "esptool"] + args


def run(args):
    print("> " + " ".join(str(part) for part in args), flush=True)
    return subprocess.run(args)


def check_esptool():
    try:
        result = subprocess.run(esptool(["version"]), capture_output=True, text=True)
    except OSError as error:
        raise Fail(f"无法启动 esptool: {error}")
    if result.returncode != 0:
        raise Fail(
            "未安装 esptool，请先执行:\n"
            f"    {Path(sys.executable).name} -m pip install --upgrade esptool"
        )
    text = result.stdout + result.stderr
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", text)
    if not match:
        raise Fail(f"无法识别 esptool 版本:\n{text.strip()}")
    version = tuple(int(part) for part in match.groups())
    print(f"esptool 版本: {'.'.join(str(part) for part in version)}")
    if version[:2] < MIN_ESPTOOL:
        raise Fail(
            f"esptool 版本过低，ESP32-C5 需要 "
            f"{MIN_ESPTOOL[0]}.{MIN_ESPTOOL[1]} 及以上，请执行:\n"
            f"    {Path(sys.executable).name} -m pip install --upgrade esptool"
        )


def list_ports():
    try:
        from serial.tools import list_ports as serial_list_ports
    except ImportError:
        return []
    return list(serial_list_ports.comports())


def describe(port):
    text = " ".join(str(part) for part in (port.device, port.description, port.manufacturer, port.hwid))
    return text.strip()


def print_ports(ports):
    if not ports:
        print("未发现任何串口，请检查 USB 线缆、开发板供电与串口驱动")
        print("若尚未安装 esptool，请先执行: py -3 -m pip install --upgrade esptool")
        return
    print("当前可用串口:")
    for port in ports:
        print(f"    {port.device:<8} {describe(port)}")


def choose_port(explicit):
    """未指定串口时优先选择常见 USB 转串口设备"""
    if explicit:
        return explicit
    ports = list_ports()
    if not ports:
        raise Fail(
            "未找到串口，请确认已连接开发板并安装串口驱动（CH340 / CP210x 等），"
            "也可以用 --port COMx 手动指定"
        )
    matches = [port for port in ports if any(hint in describe(port).lower() for hint in PORT_HINTS)]
    candidates = matches or ports
    if len(candidates) == 1:
        print(f"使用串口 {candidates[0].device} ({describe(candidates[0])})")
        return candidates[0].device
    print_ports(ports)
    answer = input("检测到多个串口，请输入要使用的串口（例如 COM5）: ").strip()
    if not answer:
        raise Fail("未选择串口")
    return answer


def flash(port, baud, keep_flash, firmware):
    base = ["--chip", CHIP, "--port", port, "--baud", baud, "--before", "default-reset", "--after", "hard-reset"]
    if not keep_flash:
        print("\n[1/2] 整片擦除 Flash")
        if run(esptool(base + ["erase_flash"])).returncode != 0:
            raise Fail("擦除失败")
    else:
        print("\n[1/2] 跳过整片擦除，仅覆盖写入固件")
    print("\n[2/2] 写入合并固件到 0x0")
    args = esptool(base + ["write_flash"] + FLASH_ARGS + ["0x0", str(firmware)])
    if run(args).returncode != 0:
        raise Fail("写入失败")


def main():
    parser = argparse.ArgumentParser(description="ESP32-C5 BLE 网关合并固件烧录工具")
    parser.add_argument("--port", help="串口名，例如 COM5")
    parser.add_argument("--baud", default=DEFAULT_BAUD, help=f"烧录波特率，默认 {DEFAULT_BAUD}")
    parser.add_argument("--keep-flash", action="store_true", help="不整片擦除，保留其它分区内容")
    parser.add_argument("--list", action="store_true", help="只列出可用串口")
    args = parser.parse_args()

    if args.list:
        print_ports(list_ports())
        return 0

    firmware = Path(__file__).resolve().parent / FIRMWARE_NAME
    try:
        if not firmware.is_file():
            raise Fail(f"缺少固件文件 {FIRMWARE_NAME}，请与脚本放在同一目录")
        print(f"固件: {firmware.name} ({firmware.stat().st_size} 字节)")
        check_esptool()
        port = choose_port(args.port)
        flash(port, args.baud, args.keep_flash, firmware)
    except Fail as error:
        print(f"\n[错误] {error}")
        print("\n排查建议:")
        print("    1. 关闭占用串口的工具（串口助手、Arduino IDE、另一个烧录窗口）")
        print("    2. 按住 BOOT 键再点按 RESET 进入下载模式后重试")
        print("    3. 换一根支持数据传输的 USB 线，或换 USB 口")
        print("    4. 降低波特率重试，例如 --baud 115200")
        return 1
    except KeyboardInterrupt:
        print("\n已取消")
        return 1

    print("\n烧录完成，设备正在重启")
    print("首次使用请连接热点 BTGW-XXXXXX（密码 btgw-xxxxxx）打开 http://192.168.4.1 配网")
    return 0


if __name__ == "__main__":
    sys.exit(main())
