# -*- coding: utf-8 -*-
"""src/CDR 英文注释汉化批次。

只替换整行注释, 不动任何代码、error 消息字符串与标识符。
运行: python tools/patch_srccdr.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from patch_comments import apply_patch

PATCH = {
    "src/CDR/cdr_ffe_loop.m": {
        2: "    % cdr_ffe_loop  CDR 专用 FFE 的块级 LMS 自适应引擎。",
        4: "    % 调用方负责提供数据样本的判决误差, 以及 cdr_ffe 返回的回归矩阵。",
        5: "    % 边界样本不参与自适应。",
        20: "            % cdr_ffe_loop  构造一个浮点块级 LMS 引擎。",
        48: "            % update  校验输入并计算一次块级 LMS 更新。",
        60: "            % updateFast  对调用方已保证合法的 double 数组计算一次更新。",
        61: "            % dataRegressor 为 BlockSize×TapCount, errorVector 为 1×BlockSize",
        62: "            % 行向量。本路径不更新任何诊断量。",
        69: "            % updateSsLms  符号-符号 LMS: 校验输入并计算一次块级 SS-LMS 更新。",
        71: "            % 把标准 LMS 梯度 e * X / N 换成符号-符号形式",
        72: "            % sign(e) * sign(X) / N。梯度幅度与信号幅度无关且上界恒为 1,",
        73: "            % 因此 StepSize 必须相应放大",
        74: "            % (通常比标准 LMS 的 mu 大 100~300 倍)。",
        86: "            % updateSsLmsFast  对调用方已保证合法的 double 数组做符号-符号 LMS。",
        87: "            % gradient = sign(errorVector) * sign(dataRegressor) / BlockSize。",
        88: "            % 本路径不更新任何诊断量。",
        95: "            % setStepSize  修改 LMS 步长, 不复位任何状态。",
        101: "            % resetState  清空自适应诊断量与更新计数。",
        108: "            % getState  返回 LMS 配置与最近一次更新的结果。",
    },
    "src/CDR/cdr_top.m": {
        165: "            % 第一级(capture -> settle)的 mu 降档门控: 判决导向眼 SNR 的",
        166: "            % 平均值越过 SnrSettleThresholdDb。眼睛张开才是放慢 FFE 的",
        167: "            % 真实前提。(历史上的 outer-dLev 位移门控已于 2026-09-26 移除:",
        168: "            % 它本质上是一个隐式的漂移速率门限, 缓慢爬升的 dLev 在眼睛",
        169: "            % 还闭着的时候就能满足它, 于是过早触发降档, 把 FFE 步长砍掉",
        170: "            % 20 倍, 眼睛反而再也张不开。)",
    },
}

if __name__ == "__main__":
    apply_patch(PATCH)
