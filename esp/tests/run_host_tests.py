#!/usr/bin/env python3
"""提取实际管理器调度代码，以模拟时间和适配器执行主机验证"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
cjson = root / 'managed_components/espressif__cjson/cJSON'
source = (root / 'components/device_manager/gateway_manager.c').read_text()
body = source[source.index('#define GW_SEEN_LIMIT'):source.index('static esp_err_t send_json')]
a, b = body.index('void gw_manager_init'), body.index('void gw_manager_pause')
body = body[:a] + body[b:]
# HTTP 保存状态不参与调度测试
body = body.replace('static bool s_restarting;\n', '')
with tempfile.TemporaryDirectory(prefix='esp-manager-tests-') as directory:
    work = Path(directory)
    (work / 'manager_under_test.inc').write_text(body)
    protocol = (root / 'components/gateway_core/gateway_protocol.c').read_text()
    protocol = '\n'.join(line for line in protocol.splitlines()
                         if not (line.startswith('#include "') or line == '#include <stdatomic.h>'))
    (work / 'protocol_under_test.inc').write_text(protocol)
    for name in ('test_policy', 'test_manager', 'test_protocol'):
        binary = work / name
        command = ['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations', '-DCJSON_NESTING_LIMIT=16', '-fsanitize=address,undefined',
                   '-I' + str(root / 'components/device_registry/include'), '-I' + str(cjson), '-I' + str(work),
                   str(root / f'tests/{name}.c'), str(root / 'components/device_registry/device_config.c'), str(cjson / 'cJSON.c'),
                   '-o', str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)
