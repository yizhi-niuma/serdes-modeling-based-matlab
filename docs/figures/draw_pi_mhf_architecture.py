# -*- coding: utf-8 -*-
"""PI MHF Path 架构框图 (依据 7 张原理图 + BIN2PI_2nd_8bit VerilogA)
生成: docs/figures/pi_mhf_architecture.png
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
    "in":   ("#eaf3fb", "#2c6fad"),   # 输入
    "pre":  ("#e8f6ee", "#1e7d4f"),   # pre-buffer
    "core": ("#fdf3e3", "#c07817"),   # PI core
    "post": ("#f6ecf9", "#8244a5"),   # post-buffer
    "dig":  ("#fdeaea", "#b33636"),   # 数字码链
    "idac": ("#f2f2f2", "#555555"),   # IDAC
    "ctrl": ("#fffbe6", "#9a8a00"),   # 控制轨
}

def box(x, y, w, h, text, kind, fs=9, lw=1.4, weight="normal"):
    fc, ec = C[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.5",
                                fc=fc, ec=ec, lw=lw, mutation_scale=1))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
            fontsize=fs, color="#222", fontweight=weight, linespacing=1.5)

def container(x, y, w, h, title, kind, fs=10):
    fc, ec = C[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.5",
                                fc="none", ec=ec, lw=2.0, mutation_scale=1))
    ax.text(x + w / 2, y + h - 2.0, title, ha="center", va="center",
            fontsize=fs, color=ec, fontweight="bold")

def arrow(x1, y1, x2, y2, label="", color="#333", lw=1.6, fs=8,
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
ax.text(80, 87.5, "PI MHF Path 电路架构框图", ha="center", fontsize=15,
        fontweight="bold")
ax.text(80, 84.2, "四分之一速率相位插值支路: 8-bit / 360° = 4 UI, 256 步 (1/64 UI 分辨率) · MF=14 GHz / HF=28 GHz 双频段",
        ha="center", fontsize=9.5, color="#555")

# ---------------- 时钟输入 ----------------
box(2, 46, 14, 12, "CMN 公共时钟\nCKI_I / IB / Q / QB\n(CML, 暂定 400 mVppd)", "in",
    fs=8.8, weight="bold")

# ---------------- Pre-buffer ----------------
container(20, 34, 26, 32, "Pre-Buffer IQ", "pre")
box(22, 50, 22, 10, "I 路 CML 再生级\n(差分对 + 1:10 尾镜像)", "pre", fs=8.5)
box(22, 37, 22, 10, "Q 路 CML 再生级\n(结构同上)", "pre", fs=8.5)

# ---------------- PI core ----------------
container(52, 30, 40, 36, "PI MHF Core (电流域矢量求和)", "core")
qw = 8.4
for i, q in enumerate(["A (I)", "B (IB)", "C (Q)", "D (QB)"]):
    box(54 + i * (qw + 1.0), 44, qw, 14, f"CML\n单元\n{q}", "core", fs=8.5)
ax.text(72, 39.5, "B/D 与 A/C 同时钟反接 → ±I / ±Q 四基向量",
        ha="center", fontsize=8.2, color="#c07817")
ax.text(72, 35.5, "四单元输出并联于同一电感负载, 相位 = IBN_A..D 加权矢量和",
        ha="center", fontsize=8.2, color="#c07817")

# ---------------- Post-buffer ----------------
container(98, 38, 22, 24, "Post-Buffer", "post")
box(100, 42, 18, 13, "CML 输出级\n(与 pre-buf 复用\n同一单元 cell)", "post", fs=8.5)

# ---------------- 输出 ----------------
arrow(120, 50, 128, 50, "", color="#333", lw=2.2)
ax.text(133, 50, "OP / ON\n插值时钟输出", ha="center", va="center",
        fontsize=9, fontweight="bold")

# ---------------- 主信号流 ----------------
arrow(16, 52, 20, 52, "", color="#2c6fad", lw=2.0)
arrow(46, 55, 52, 55, "PI_IN_I/IB", color="#1e7d4f", lw=1.9, dy=2.0)
arrow(46, 42, 52, 47, "PI_IN_Q/QB", color="#1e7d4f", lw=1.9, dy=-2.2)
arrow(92, 50, 98, 50, "PI_OP/ON", color="#c07817", lw=2.0, dy=2.0)

# ---------------- 三级同构注释 ----------------
ax.text(70, 26.5,
        "三级同构级结构:  NMOS CML 核 (AC 耦合 211 fF · VCM 经 23.6 kΩ 定共模 · 1:10 尾电流镜像, 4 管串联堆叠)"
        "  +  PMOS 频段开关 (totalM=156)  +  纯电感多抽头 peaking 负载 (选抽头调谐 14 / 28 GHz)",
        ha="center", fontsize=8.5, color="#666", style="italic")

# ---------------- 数字码链 ----------------
container(20, 68, 100, 13, "相位码产生 (数字域)", "dig", fs=9.5)
box(22, 70.5, 16, 7.5, "相位控制字\nBIN<7:0>", "dig", fs=8.5)
box(44, 70.5, 30, 7.5, "BIN2PI_2nd_8bit (VerilogA)\n二阶插值: 0°/90° 主基 + ±45° 辅基\n→ 格雷码 KGI1/KGQ1<6:0>, KGI2/KGQ2<5:0>", "dig", fs=7.8)
box(80, 70.5, 22, 7.5, "Gray → 温度计\n解码器", "dig", fs=8.5)
arrow(38, 74.2, 44, 74.2, "", color="#b33636", lw=1.5)
arrow(74, 74.2, 80, 74.2, "", color="#b33636", lw=1.5)
arrow(102, 74.2, 112, 74.2, "T 码", color="#b33636", lw=1.5, dy=1.6)

# ---------------- IDAC ----------------
box(112, 66, 36, 12, "IDAC (见 IDAC 章节)\nTA..TD<126:0> 温度计加权\n+ 3-bit 粗调 / MHF 选路", "idac",
    fs=8.5, weight="bold")
arrow(118, 66, 33, 60.5, "IBN_PRE_BUF_I/Q", color="#555", lw=1.6, dx=-14, dy=2.5)
arrow(126, 66, 72, 58.5, "IBN_A / B / C / D  (插值权重)", color="#555", lw=1.8, dx=-6, dy=2.5)
arrow(134, 66, 109, 55.5, "IBN_POST_BUF", color="#555", lw=1.6, dx=5, dy=2.5)

# ---------------- 控制轨 ----------------
box(20, 12, 100, 6.5,
    "全局控制:  PDB (低有效掉电, 镜像栅/VCM_ 拉至 VSS)  ·  VCM = 450 mV (标称)  ·  "
    "ENB_MF / ENB_HF (低有效, 严格互斥; MF=14 GHz, HF=28 GHz; 仅关断时可同时无效)",
    "ctrl", fs=8.5)
for xc in (33, 72, 109):
    arrow(xc, 18.5, xc, 23.5, "", color="#9a8a00", lw=1.4)

import os
out = os.path.join("docs", "figures", "pi_mhf_architecture.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
fig.savefig(out, bbox_inches="tight", facecolor="white")
print("saved:", os.path.abspath(out))
