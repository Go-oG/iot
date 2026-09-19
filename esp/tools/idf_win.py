#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 MSYS/Git Bash 下启动 ESP-IDF 的 idf.py。

Git Bash 会强制注入 MSYSTEM，而 ESP-IDF 6.1 的 tools/idf.py 在检测到该变量时
只打印一条警告就直接结束，不调用 main()，表现为构建静默成功但没有任何输出。
这里在导入前移除该变量，再以 __main__ 方式运行真正的 idf.py。
"""

import os
import runpy
import sys

IDF_PATH = os.environ.get("IDF_PATH")
if not IDF_PATH:
    sys.exit("IDF_PATH 未设置，请先 source tools/env.sh")

os.environ.pop("MSYSTEM", None)

script = os.path.join(IDF_PATH, "tools", "idf.py")
# idf.py 依赖同目录下的 python_version_checker 等模块
sys.path.insert(0, os.path.dirname(script))
sys.argv = [script] + sys.argv[1:]
runpy.run_path(script, run_name="__main__")
