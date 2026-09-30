# -*- coding: utf-8 -*-
"""PI TOP 顶层架构框图 (依据 PI TOP 顶层原理图 + symbol)
生成: docs/figures/pi_top_architecture.png
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
    "in":   ("#eaf3fb", "#2c6fad"),
    "idac": ("#f2f2f2", "#555555"),
    "vcm":  ("#e8f6ee", "#1e7d4f"),
    "mhf":  ("#fdf3e3", "#c07817"),
    "lf":   ("#fdeaea", "#b33636"),
    "ctrl": ("#fffbe6", "#9a8a00"),
}

def box(x, y, w, h, text, kind, fs=8.5, lw=1.4, weight="normal"):
    fc, ec = C[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.5",
                                fc=fc, ec=ec, lw=lw, mutation_scale=1))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
            fontsize=fs, color="#222", fontweight=weight, linespacing=1.5)

def container(x, y, w, h, title, kind, fs=9.5):
    fc, ec = C[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.5",
                                fc="none", ec=ec, lw=2.0, mutation_scale=1))
    ax.text(x + w / 2, y + h - 1.9, title, ha="center", va="center",
            fontsize=fs, color=ec, fontweight="bold")

def arrow(x1, y1, x2, y2, label="", color="#333", lw=1.6, fs=7.8,
          dx=0, dy=1.6):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", color=color, lw=lw,
                                shrinkA=1, shrinkB=1))
    if label:
        ax.text((x1 + x2) / 2 + dx, (y1 + y2) / 2 + dy, label,
                ha="center", va="center", fontsize=fs, color=color,
                bbox=dict(boxstyle="round,pad=0.15", fc="white",
                          ec="none", alpha=1.0))

# ---------------- 标题 ----------------
ax.text(80, 87.6, "PI TOP 顶层架构框图", ha="center", fontsize=15, fontweight="bold")
ax.text(80, 84.6, "四子块: IDAC (7-bit + 电流 MUX) · Vbias_CMLbuffer (VCM 产生) · MHF Path · LF Path"
                  " — 命名约定: *_CML = MHF 支路, *_CMOS = LF 支路", ha="center", fontsize=9.2, color="#555")

# ---------------- 左侧输入 ----------------
box(2, 66, 15, 13, "数字控制\nTA..TD<126:0>\nICTRL_PI/PRE/POST\n<2:0> · EN_IDAC", "in", fs=7.6, weight="bold")
box(2, 50, 15, 10, "CKI_I/IB/Q/QB\n_CML\n(MHF 四相)", "in", fs=7.8, weight="bold")
box(2, 33, 15, 10, "CKI_I/IB/Q/QB\n_CMOS\n(LF 四相)", "in", fs=7.8, weight="bold")
box(2, 15, 15, 13, "IBN_PI / IBN_BUF\n(外部基准 10 μA)\nEN_VCM\nVCM_CTRL<7:0>", "in", fs=7.2, weight="bold")

# ---------------- IDAC ----------------
container(21, 57, 70, 23, "IDAC  Hyperlink_rx_clk_PI_IDAC_7bit  (VDD 域, PMOS 镜像阵列)", "idac")
box(23, 60, 20, 9.5, "PI 7-bit 温度计 ×4\nTA..TD<126:0> (低有效)\n≤2.5 μA/单元", "idac", fs=7.2)
box(45, 60, 19, 9.5, "BUF 镜像阵列\nPRE_I/PRE_Q/POST\nICTRL 3-bit 粗调", "idac", fs=7.2)
box(66, 60, 23, 9.5, "电流 MUX (二选一)\nEN_CML → *_MHF\nEN_CMOS → *_LF", "idac", fs=7.2)
ax.text(56, 58.3, "EN_IDAC → PDB 全局掉电 (VBP 拉 VDD 关断全部镜像)", ha="center",
        fontsize=7.4, color="#777", style="italic")

# ---------------- Vbias ----------------
box(21, 42, 26, 10, "Vbias_CMLbuffer\nVCM_CTRL<7:0> 独热 8 档\n300–500 mV → VCM (共用)", "vcm", fs=7.8, weight="bold")

# ---------------- MHF Path ----------------
container(98, 46, 40, 23, "MHF Path (Hyperlink_rx_clk_PI_MHF_Path)", "mhf")
box(100, 49, 36, 14, "CML 输入 · LC 谐振负载\nEN_CML 使能 · EN_MF/EN_HF 频段\nMF 14 GHz / HF 28 GHz\n8-bit 温度计权重矢量插值", "mhf", fs=7.8)

# ---------------- LF Path ----------------
container(98, 14, 40, 24, "LF Path (Hyperlink_rx_clk_PI_LF_Path)", "lf")
box(100, 17, 36, 15, "CMOS 输入 · RC+带限两级正弦化\nEN_CMOS 使能 · PATH_SEL<2:0> 斜率档\n≈0.1–7 GHz 连续覆盖\n同一套温度计权重矢量插值", "lf", fs=7.8)

# ---------------- 输出 ----------------
arrow(138, 58, 146, 58, "", color="#c07817", lw=2.2)
ax.text(153, 58, "OP_CML\nON_CML\n≥500 mVppd\n@ 40 fF", ha="center", va="center", fontsize=7.8, fontweight="bold")
arrow(138, 26, 146, 26, "", color="#b33636", lw=2.2)
ax.text(153, 26, "OP_CMOS\nON_CMOS\n≥500 mVppd\n@ 20 fF", ha="center", va="center", fontsize=7.8, fontweight="bold")
ax.text(148, 42, "两对差分输出\n独立引出\n(片内不合并)", ha="center", fontsize=7.6,
        color="#777", style="italic")

# ---------------- 连线 ----------------
arrow(17, 72, 21, 72, "", color="#2c6fad", lw=1.9)
arrow(17, 55, 98, 55, "CKI_*_CML ×4", color="#2c6fad", lw=1.8, dx=-18, dy=1.8)
arrow(17, 38, 78, 38, "", color="#2c6fad", lw=1.8)
arrow(78, 38, 98, 30, "CKI_*_CMOS ×4", color="#2c6fad", lw=1.8, dx=-6, dy=2.2)
arrow(17, 21, 21, 45, "", color="#2c6fad", lw=1.6)
arrow(17, 25, 30, 57, "IBN_PI / IBN_BUF", color="#2c6fad", lw=1.6, dx=6, dy=-9)

arrow(91, 68, 108, 63.5, "IBN_A..D / PRE / POST ×7 (_MHF)", color="#555", lw=1.9, dx=-6, dy=2.6)
arrow(84, 57, 108, 32.5, "×7 (_LF)", color="#555", lw=1.9, dx=4, dy=6)
arrow(47, 49, 98, 52, "VCM", color="#1e7d4f", lw=1.7, dy=1.8)
arrow(47, 45, 98, 28, "VCM", color="#1e7d4f", lw=1.7, dx=-8, dy=2.0)

# ---------------- 控制轨 ----------------
box(21, 3.5, 117, 7,
    "使能体系 (复位默认全 0, 高有效):  EN_CML(MHF)/EN_CMOS(LF) 互斥选路且同送 IDAC MUX · EN_MF/EN_HF 频段互斥"
    " (软件保证) · PATH_SEL<2:0> · EN_IDAC · EN_VCM  ·  TA..TD 低有效默认全 1  ·  VDD=750 mV 单电源域", "ctrl", fs=7.6)
arrow(56, 10.5, 56, 57, "", color="#9a8a00", lw=1.3)
arrow(112, 10.5, 112, 14, "", color="#9a8a00", lw=1.3)
arrow(118, 10.5, 118, 46, "", color="#9a8a00", lw=1.3)

import os
out = os.path.join("docs", "figures", "pi_top_architecture.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
fig.savefig(out, bbox_inches="tight", facecolor="white")
print("saved:", os.path.abspath(out))
