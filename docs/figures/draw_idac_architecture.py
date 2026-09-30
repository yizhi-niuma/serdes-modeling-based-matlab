# -*- coding: utf-8 -*-
"""IDAC 偏置电路架构框图 (依据 5 张原理图整理)
生成: docs/figures/idac_architecture.png
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

fig, ax = plt.subplots(figsize=(16, 9), dpi=170)
ax.set_xlim(0, 160)
ax.set_ylim(0, 90)
ax.axis("off")

C = {
    "ref":  ("#eaf3fb", "#2c6fad"),   # 带隙基准
    "bias": ("#e8f6ee", "#1e7d4f"),   # 偏置源
    "pi":   ("#fdf3e3", "#c07817"),   # PI 阵列
    "buf":  ("#f6ecf9", "#8244a5"),   # BUF 阵列
    "mux":  ("#fdeaea", "#b33636"),   # 电流 MUX
    "load": ("#f2f2f2", "#555555"),   # 负载
    "ctrl": ("#fffbe6", "#9a8a00"),   # 控制轨
}

def box(x, y, w, h, text, kind, fs=9.5, lw=1.4, weight="normal", style="round,pad=0.6"):
    fc, ec = C[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle=style,
                                fc=fc, ec=ec, lw=lw, mutation_scale=1))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
            fontsize=fs, color="#222", fontweight=weight, linespacing=1.5)

def container(x, y, w, h, title, kind, fs=10.5):
    fc, ec = C[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.6",
                                fc="none", ec=ec, lw=2.0, mutation_scale=1))
    ax.text(x + w / 2, y + h - 2.2, title, ha="center", va="center",
            fontsize=fs, color=ec, fontweight="bold")

def arrow(x1, y1, x2, y2, label="", color="#333", lw=1.6, fs=8.5,
          dx=0, dy=1.6, ha="center"):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", color=color, lw=lw,
                                shrinkA=1, shrinkB=1))
    if label:
        ax.text((x1 + x2) / 2 + dx, (y1 + y2) / 2 + dy, label,
                ha=ha, va="center", fontsize=fs, color=color,
                bbox=dict(boxstyle="round,pad=0.15", fc="white",
                          ec="none", alpha=1.0))

# ---------------- 标题 ----------------
ax.text(80, 87.5, "PI IDAC 偏置电路架构框图", ha="center", fontsize=15,
        fontweight="bold")
ax.text(80, 83.8, "为相位插值器 (PI) CML buffer 及 Pre-buffer / Post-buffer 提供可编程电流偏置",
        ha="center", fontsize=10, color="#555")

# ---------------- 带隙基准 ----------------
box(2, 44, 14, 10, "上级 bias 输入\nIBN_PI / IBN_BUF\n(暂定各 10 μA)", "ref", fs=8.8, weight="bold")

# ---------------- 偏置源 ----------------
container(20, 24, 29, 48, "IDAC 偏置源 bias_source", "bias")
ax.text(34.5, 66.2, "(外部基准两路: IBN_PI / IBN_BUF, PI 支路电流远小于 BUF)", ha="center",
        fontsize=8, color="#1e7d4f", style="italic")
box(22, 54, 25, 9,  "PI 粗调  3-bit BIN\n固定 3μ + {1,2,4}μ 加权", "bias")
box(22, 41, 25, 9,  "PRE_BUF 粗调  3-bit BIN\n固定 30μ + {10,20,40}μ", "bias")
box(22, 28, 25, 9,  "POST_BUF 粗调  3-bit BIN\n固定 30μ + {10,20,40}μ", "bias")

arrow(16, 51.5, 20, 51.5, "IBN_PI", color="#2c6fad", lw=1.8, fs=8, dy=1.8)
arrow(16, 46.5, 20, 46.5, "IBN_BUF", color="#2c6fad", lw=1.8, fs=8, dy=-1.8)

# ---------------- IDAC 输出阵列 ----------------
container(55, 20, 48, 54, "IDAC 输出阵列 array_top   (PMOS cascode 电流镜 · VDD 域)", "pi")
# PI 行
ax.text(79, 65.8, "PI 7-bit 温度计 IDAC × 4:  常开 4 单元 + 开关单元 × 127,  ≤ 2.5 μA/单元",
        ha="center", fontsize=8.8, color="#c07817")
pw = 10.2
for i, q in enumerate(["A (I)", "B (IB)", "C (Q)", "D (QB)"]):
    box(57.5 + i * (pw + 1.4), 52, pw, 11, f"PI IDAC\n{q}", "pi", fs=9.5)
# BUF 行
ax.text(79, 42.3, "BUF 固定比镜像 IDAC:  常开 ≤100 μA + 20 单元阵列 ≤400 μA",
        ha="center", fontsize=8.8, color="#8244a5")
bw = 14.0
for i, q in enumerate(["PRE_BUF I", "PRE_BUF Q", "POST_BUF"]):
    box(57.5 + i * (bw + 1.6), 28, bw, 11, f"BUF IDAC\n{q}", "buf", fs=9.5)
ax.text(79, 23.7, "PD/PDB 掉电: pch_lvt 开关将 VBP 拉至 VDD, 关断全部镜像单元",
        ha="center", fontsize=8.3, color="#888", style="italic")

# 偏置源 → 阵列 (内部粗调后参考电流, 外部信号仅 IBN_PI / IBN_BUF 两路)
arrow(49, 58.5, 55, 58.5, "", color="#1e7d4f", lw=1.8)
arrow(49, 45.5, 55, 36.5, "", color="#1e7d4f", lw=1.8)
arrow(49, 32.5, 55, 31.0, "", color="#1e7d4f", lw=1.8)

# 温度计码输入
ax.text(79, 79.5, "TA / TB / TC / TD <126:0>  I/IB/Q/QB 四相温度计码, 低有效  (由 PI 相位控制字动态译码 → 插值权重)",
        ha="center", fontsize=9.2, color="#b35900", fontweight="bold")
for i in range(4):
    xq = 57.5 + i * (pw + 1.4) + pw / 2
    arrow(xq, 77.5, xq, 63.6, "", color="#b35900", lw=1.4)

# ---------------- 电流 MUX ----------------
container(109, 24, 20, 48, "电流 MUX", "mux", fs=10.5)
ax.text(119, 48, "IPI current MUX\n/ IBUF\n\n差分电流开关\nEN_MHF / EN_LF\n严格互斥二选一\n(可同时为 0 全关断)",
        ha="center", va="center", fontsize=9, color="#b33636")

# 阵列 → MUX
arrow(103, 57.5, 109, 57.5, "IA·IB·IC·ID\n(0.8~2.5 mA 满幅)", color="#c07817",
      lw=2.2, dy=4.2)
arrow(103, 35.5, 109, 39.5, "IPRE_I · IPRE_Q", color="#8244a5", lw=1.9, dy=3.0)
arrow(103, 30.5, 109, 29.5, "IPOST", color="#8244a5", lw=1.9, dy=-2.0)

# ---------------- 负载 ----------------
ax.text(145, 71.5, "每路二选一送 MHF / LF 通路", ha="center", fontsize=8.5,
        color="#777", style="italic")
box(133, 52, 24, 15, "PI 相位插值核\nCML buffer × 4 相\nI / IB / Q / QB\n(尾电流 = 插值权重)",
    "load", fs=9.5, weight="bold")
box(133, 37, 24, 10, "Pre-buffer I / Q\n(PI 输入时钟 CML 缓冲)", "load", fs=9.5)
box(133, 24, 24, 9, "Post-buffer\n(PI 输出时钟 CML 缓冲)", "load", fs=9.5)

# MUX → 负载
arrow(129, 59.5, 133, 59.5, "I*_MHF / I*_LF", color="#333", lw=2.0, dy=2.0)
arrow(129, 42, 133, 42, "", color="#333", lw=1.8)
arrow(129, 28.5, 133, 28.5, "", color="#333", lw=1.8)

# ---------------- 控制轨 ----------------
box(20, 8, 109, 6.5,
    "控制 / 使能配送 (X2 反相器缓冲链):   PD / PDB  ·  ICTRL_PI<2:0>  ·  ICTRL_PRE_BUF<2:0>  ·  ICTRL_POST_BUF<2:0>  ·  EN/ENB_MHF  ·  EN/ENB_LF",
    "ctrl", fs=9)
arrow(34, 14.5, 34, 23.2, "3-bit×3", color="#9a8a00", lw=1.4, dx=4.5, dy=-1.0)
arrow(79, 14.5, 79, 19.2, "PD/PDB", color="#9a8a00", lw=1.4, dx=5.5, dy=-1.0)
arrow(119, 14.5, 119, 23.2, "EN_MHF/LF", color="#9a8a00", lw=1.4, dx=6.5, dy=-1.0)

import os
out = os.path.join("docs", "figures", "idac_architecture.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
fig.savefig(out, bbox_inches="tight", facecolor="white")
print("saved:", os.path.abspath(out))
