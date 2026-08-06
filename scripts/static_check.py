#!/usr/bin/env python3
"""Lynx 4.0 Android/iOS/HarmonyOS 三端静态验收总入口。"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run_checker(relative: str, title: str) -> tuple[int, int, int, int, str]:
    process = subprocess.run(
        [sys.executable, str(ROOT / relative)],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    output = process.stdout.rstrip()
    match = re.search(r"结果:\s*(\d+) PASS,\s*(\d+) WARN,\s*(\d+) FAIL", output)
    if match is None:
        return process.returncode or 1, 0, 0, 1, f"{title}\n{output}\n[FAIL] 无法解析子检查器结果"
    return process.returncode, int(match.group(1)), int(match.group(2)), int(match.group(3)), f"{title}\n{output}"


def main() -> int:
    android_ios = run_checker('scripts/static_check_android_ios.py', '========== Android / iOS ==========')
    harmony = run_checker('harmony/scripts/check_harmony_shell.py', '========== HarmonyOS ==========')

    print(android_ios[4])
    print()
    print(harmony[4])

    total_pass = android_ios[1] + harmony[1]
    total_warn = android_ios[2] + harmony[2]
    total_fail = android_ios[3] + harmony[3]
    print('\n========== 三端汇总 ==========')
    print(f'结果: {total_pass} PASS, {total_warn} WARN, {total_fail} FAIL')
    print('说明: 本命令仅执行静态验收；构建/安装/运行需分别查看 Android、iOS 和 HarmonyOS 验收记录。')
    return 1 if android_ios[0] != 0 or harmony[0] != 0 or total_fail else 0


if __name__ == '__main__':
    sys.exit(main())
