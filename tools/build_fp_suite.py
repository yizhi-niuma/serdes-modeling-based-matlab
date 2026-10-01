# -*- coding: utf-8 -*-
"""从 _v1 套件派生出定点版 _fp 套件。

做法是整目录复制 + 精确文本替换，而不是手写一份 1563 行的 runner。这样可以
保证 fp 与 float 两条路径**除了被替换的那几行以外逐字相同** —— 这正是做
apples-to-apples 对拍所需要的：任何结果差异都只可能来自定点化本身。

运行: python tools/build_fp_suite.py
"""
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SRC = os.path.join(REPO, 'validation', 'CDR', 'test_cdr_three_loop_wi_ppm_v1')
DST = os.path.join(REPO, 'validation', 'CDR', 'test_cdr_three_loop_wi_ppm_fp')

# (旧片段, 新片段, 适用文件后缀过滤)
REPLACEMENTS = [
    # 路径装配函数改名
    ('setup_cdr_three_loop_wi_ppm_v1_paths',
     'setup_cdr_three_loop_wi_ppm_fp_paths'),

    # 顶层换成定点实现
    ('    cfg = cdr_top.defaultConfig();',
     '    cfg = cdr_fx.cdr_top.defaultConfig();'),
    ('    top = cdr_top(cfg);',
     '    top = cdr_fx.cdr_top(cfg);'),

    # 频率态门控由 2048 深滑窗求 mean/std 改为三条指数平均，
    # 窗口长度参数被三个 alpha 取代。
    ('    cfg.FfeGateFreqWindowBlocks = piLockWindowBlocks;',
     '    % 频率态门控已改用指数平均（见 src/CDR/+cdr_fx/loop_monitor.m）：\n'
     '    % 原来的 2048 深滑窗 + 宽加法树 + 54 位平方和累加器，被三个寄存器\n'
     '    % 取代（快/慢两条 EWMA 加一条绝对偏差 EWMA），面积与功耗低一个数量级。\n'
     '    % 窗口长度参数因此不再存在。\n'
     '    cfg.FfeGateAlphaFast = options.FreqAlphaFast;\n'
     '    cfg.FfeGateAlphaSlow = options.FreqAlphaSlow;\n'
     '    cfg.FfeGateAlphaMad = options.FreqAlphaMad;'),

    # 门控最小块号：EWMA 需要先充分建立起来才有意义，不能从第 1 块就判。
    ('    cfg.FfeGateFreqMinBlock = 1;',
     '    cfg.FfeGateFreqMinBlock = options.FreqGateMinBlock;'),

    # 新增三个 alpha 与门控起判块号的默认值
    ('defaults.FreqMeanHalfDiffTol',
     'defaults.FreqAlphaFast = 1 / 64;\n'
     'defaults.FreqAlphaSlow = 1 / 512;\n'
     'defaults.FreqAlphaMad = 1 / 256;\n'
     'defaults.FreqGateMinBlock = 2048;\n'
     'defaults.FreqMeanHalfDiffTol'),
]

# 文件头标题行（各文件第 2 行的函数名注释）保持原样，只在 runner 顶部加一段
# 说明，点明它与 _v1 的关系。
RUNNER_BANNER_OLD = '%CDR_THREE_LOOP_PPM 频偏条件下的 CDR+dlev+CDR-FFE 三环捕获。'
RUNNER_BANNER_NEW = (
    '%CDR_THREE_LOOP_PPM 频偏条件下的 CDR+dlev+CDR-FFE 三环捕获（定点版）。\n'
    '%\n'
    '%   本文件由 test_cdr_three_loop_wi_ppm_v1 的同名 runner 派生，除以下几处\n'
    '%   外逐字相同：顶层换成 cdr_fx.cdr_top、频率态门控的滑窗参数换成三个 EWMA\n'
    '%   系数、路径装配函数改名。保持逐字相同是刻意的 —— 这样浮点与定点两条\n'
    '%   路径的任何结果差异都只可能来自定点化本身，而不是 runner 的实现分歧。')


def main():
    if os.path.exists(DST):
        shutil.rmtree(DST)
    shutil.copytree(SRC, DST, ignore=shutil.ignore_patterns('result'))
    os.makedirs(os.path.join(DST, 'result'), exist_ok=True)

    # 路径装配文件改名
    old_setup = os.path.join(DST, 'setup_cdr_three_loop_wi_ppm_v1_paths.m')
    new_setup = os.path.join(DST, 'setup_cdr_three_loop_wi_ppm_fp_paths.m')
    if os.path.exists(old_setup):
        os.rename(old_setup, new_setup)

    changed = 0
    for root, _dirs, files in os.walk(DST):
        for name in files:
            if not name.endswith('.m'):
                continue
            path = os.path.join(root, name)
            with open(path, 'rb') as fh:
                raw = fh.read()
            text = raw.decode('utf-8')
            crlf = '\r\n' in text
            flat = text.replace('\r\n', '\n') if crlf else text
            before = flat

            for old, new in REPLACEMENTS:
                flat = flat.replace(old, new)
            if name == 'cdr_three_loop_ppm.m' and RUNNER_BANNER_OLD in flat:
                flat = flat.replace(RUNNER_BANNER_OLD, RUNNER_BANNER_NEW, 1)

            if flat != before:
                out = flat.replace('\n', '\r\n') if crlf else flat
                with open(path, 'wb') as fh:
                    fh.write(out.encode('utf-8'))
                changed += 1
                print('  改写 %s' % os.path.relpath(path, REPO))

    print('完成，改写 %d 个文件。' % changed)


if __name__ == '__main__':
    main()
