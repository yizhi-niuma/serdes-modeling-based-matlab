# -*- coding: utf-8 -*-
"""把 5 个仍按已删除 loop_monitor 接口调用的站点改到现有 API。

背景：2026-09-30 的重构把 center-touch FFE 写门控整条从 loop_monitor 删除
（构造器 4 参 -> 0 参，updateFfeGate / update 删除）。cdr_top 的生产路径早已
切到 freq-state，但以下外围站点没跟着改，一调即崩：

  MATLAB:TooManyInputs        <- loop_monitor(500, 100, 3, 1)
  MATLAB:noSuchMethodOrField  <- monitor.updateFfeGate(...)

本脚本按字节做精确文本替换，保留 CRLF。任一处匹配不到即整体中止不写盘。
运行: python tools/patch_loop_monitor_callsites.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# ---------------------------------------------------------------------------
# 1) 两个 helper + 两份 _v1 拷贝：删掉已失效的 center-touch 回放，如实返回 NaN。
#    主路径（result.Stage2GateBlock）不动，它对所有现代 run 都有效。

OLD_REPLAY = """
runOptions = result.RunOptions;
monitor = loop_monitor(runOptions.FfeFreezeMinModeOccurrences, ...
    runOptions.FfeFreezeMinEvents, runOptions.FfeFreezeBandHalfWidth, 1);
unwrappedTrace = reshape(double(result.UnwrappedPhaseTrace( ...
    rowIndex, 1:double(result.NumBlocks))), 1, []);
fireBlock = NaN;
for blockIndex = 1:double(result.NumBlocks)
    if monitor.updateFfeGate(unwrappedTrace(blockIndex), blockIndex)
        fireBlock = blockIndex;
        return;
    end
end
end
"""

OLD_REPLAY_EYES = """
runOptions = result.RunOptions;
monitor = loop_monitor(runOptions.FfeFreezeMinModeOccurrences, ...
    runOptions.FfeFreezeMinEvents, runOptions.FfeFreezeBandHalfWidth, 1);
unwrappedTrace = reshape(double( ...
    result.UnwrappedPhaseTrace(rowIndex, :)), 1, []);
fireBlock = NaN;
for blockIndex = 1:double(result.NumBlocks)
    if monitor.updateFfeGate(unwrappedTrace(blockIndex), blockIndex)
        fireBlock = blockIndex;
        return;
    end
end
end
"""


def new_replay(warn_id):
    template = """
% 旧 MAT 没有 Stage2GateBlock 字段。此前这里会回放 center-touch 写门控来补算
% 该块号，但该门控已于 2026-09-30 随重构从 loop_monitor 整体删除(它在有频偏时
% 因 PI code 持续爬升而永不触发，已被 freq-state 判据取代)，因此无法再回放。
% 这里如实返回 NaN 并告警，而不是改用另一条语义不同的判据冒充原结果。
warning('@@ID@@:Stage2GateBlockUnavailable', ...
    ['结果 MAT 缺少 Stage2GateBlock 字段，且 center-touch 写门控已从 ' ...
    'loop_monitor 删除、无法回放，第 %d 个起始相位的 stage-2 块号记为 NaN。'], ...
    rowIndex);
fireBlock = NaN;
end
"""
    return template.replace('@@ID@@', warn_id)


# ---------------------------------------------------------------------------
# 2) tests/CDR/test_freq_state_gate.m：构造器已是零参。

OLD_TEST = """function mon = makeMonitor()
% Constructor arity is unchanged by the gate; use the documented 4-argument
% form and configure the gate separately.
mon = loop_monitor(500, 100, 3, 1);
end"""

NEW_TEST = """function mon = makeMonitor()
% 构造器自 2026-09-30 的 center-touch 移除后变为零参；频率态门控通过
% enableFreqStateGate 单独配置，与构造完全解耦。
mon = loop_monitor();
end"""


# ---------------------------------------------------------------------------
# 3) src/CDR/cdr_top.m：删掉两段描述已删除接口的过期注释。

OLD_CFG_COMMENT = """            % center-touch 的三个检测器参数(MinModeOccurrences / MinEvents /
            % BandHalfWidth)与 StartBlock 已于 2026-09-29 从本类配置面移除:
            % cdr_top 自 2026-09-28 起再也不调 updateFfeGate,这些值对本类行为
            % 没有任何影响。loop_monitor 的构造器仍要求它们,所以构造处(见下)
            % 传入固定的惰性常量。离线回放(make_ppm_stage_eyes /
            % write_ppm_lock_summary_txt)另建自己的 loop_monitor,用的是
            % result.RunOptions.FfeFreeze*,不受此处影响。
"""

NEW_CFG_COMMENT = """            % center-touch 的三个检测器参数(MinModeOccurrences / MinEvents /
            % BandHalfWidth)与 StartBlock 已于 2026-09-29 从本类配置面移除,
            % 2026-09-30 又随 center-touch 本体一起从 loop_monitor 删除。
            % loop_monitor 现在是零参构造, 这里不再需要传任何惰性常量。
"""

OLD_CRIT_COMMENT = """            % 2026-09-28 从 cdr_top 删除：0 ppm 下 freq-state 与它 32/32 一致，
            % 有 ppm 时 center-touch 因 PI code 持续爬升永不触发。loop_monitor
            % 仍保留 updateFfeGate 供旧 MAT 的离线回放，cdr_top 不再选用它。
"""

NEW_CRIT_COMMENT = """            % 2026-09-28 从 cdr_top 删除：0 ppm 下 freq-state 与它 32/32 一致，
            % 有 ppm 时 center-touch 因 PI code 持续爬升永不触发。该判据已于
            % 2026-09-30 从 loop_monitor 本体一并删除, 不存在任何回放路径。
"""


def patch_file(rel_path, pairs):
    abs_path = os.path.join(REPO, rel_path)
    with open(abs_path, 'rb') as fh:
        raw = fh.read()
    text = raw.decode('utf-8')
    crlf = '\r\n' in text
    flat = text.replace('\r\n', '\n') if crlf else text

    for old, new in pairs:
        if old not in flat:
            raise SystemExit('匹配失败: %s\n--- 期望片段 ---\n%s' % (rel_path, old[:200]))
        if flat.count(old) != 1:
            raise SystemExit('片段不唯一(%d 处): %s' % (flat.count(old), rel_path))
        flat = flat.replace(old, new)

    out = flat.replace('\n', '\r\n') if crlf else flat
    with open(abs_path, 'wb') as fh:
        fh.write(out.encode('utf-8'))
    print('  已修补 %s' % rel_path)


if __name__ == '__main__':
    print('修补 loop_monitor 旧接口调用点:')
    for suite in ('test_cdr_three_loop_wi_ppm', 'test_cdr_three_loop_wi_ppm_v1'):
        patch_file('validation/CDR/%s/helpers/write_ppm_lock_summary_txt.m' % suite,
                   [(OLD_REPLAY, new_replay('write_ppm_lock_summary_txt'))])
        patch_file('validation/CDR/%s/make_ppm_stage_eyes.m' % suite,
                   [(OLD_REPLAY_EYES, new_replay('make_ppm_stage_eyes'))])
    patch_file('tests/CDR/test_freq_state_gate.m', [(OLD_TEST, NEW_TEST)])
    patch_file('src/CDR/cdr_top.m',
               [(OLD_CFG_COMMENT, NEW_CFG_COMMENT),
                (OLD_CRIT_COMMENT, NEW_CRIT_COMMENT)])
    print('全部完成。')
