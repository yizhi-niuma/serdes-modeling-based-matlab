# -*- coding: utf-8 -*-
"""汇总应用 ppm 脚本的注释汉化补丁。

自动发现 tools/patch_ppm_*.py 中的 PATCH / PATCH_A / PATCH_B / PATCH_C 字典,
合并后一次性应用到两个 ppm 套件的同名脚本(两者除第 49 行的 path setup
函数名外完全相同, 所以同一份注释补丁对两者都成立)。

运行: python tools/apply_ppm_patches.py
"""
import glob
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from patch_comments import apply_patch

TARGETS = [
    'validation/CDR/test_cdr_three_loop_wi_ppm/src/cdr_three_loop_ppm/cdr_three_loop_ppm.m',
    'validation/CDR/test_cdr_three_loop_wi_ppm_v1/src/cdr_three_loop_ppm/cdr_three_loop_ppm.m',
]


def load_dicts():
    merged = {}
    for path in sorted(glob.glob(os.path.join(HERE, 'patch_ppm_*.py'))):
        name = os.path.splitext(os.path.basename(path))[0]
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        found = False
        for attr in dir(mod):
            if attr.startswith('PATCH'):
                d = getattr(mod, attr)
                if isinstance(d, dict):
                    for lineno, text in d.items():
                        if lineno in merged and merged[lineno] != text:
                            raise SystemExit('行号冲突: %d 在多个补丁里给了不同译文' % lineno)
                        merged[lineno] = text
                    found = True
        if not found:
            print('  跳过(无 PATCH 字典): %s' % os.path.basename(path))
        else:
            print('  载入 %s' % os.path.basename(path))
    return merged


if __name__ == '__main__':
    print('载入补丁:')
    edits = load_dicts()
    print('合计 %d 条译文' % len(edits))
    patch = {target: dict(edits) for target in TARGETS}
    apply_patch(patch)
