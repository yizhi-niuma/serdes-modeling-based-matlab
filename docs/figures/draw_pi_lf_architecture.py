# -*- coding: utf-8 -*-
"""PI LF Path 架构框图 (依据顶层/slope_ctrl_core/pre-buf/post-buf 原理图 + 用户确认参数)
生成: docs/figures/pi_lf_architecture.png
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
    "slope": ("#fdeaea", "#b33636"),
    "pre":  ("#e8f6ee", "#1e7d4f"),
    "core": ("#fdf3e3", "#c07817"),
    "post": ("#f6ecf9", "#8244a5"),
    "idac": ("#f2f2f2", "#555555"),
    "ctrl": ("#fffbe6", "#9a8a00"),
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
ax.text(80, 87.5, "PI LF Path 电路架构框图", ha="center", fontsize=15,
        fontweight="bold")
ax.text(80, 84.5, "低频相位插值支路: 电阻负载无谐振, 带宽覆盖至 7 GHz (下限受 core AC 耦合限制, ≈100 MHz)",
        ha="center", fontsize=9.5, color="#555")
ax.text(80, 81.3, "波形演化:  CMOS 方波 ──(slope_ctrl RC)──→ 三角波 ──(pre-buffer 带限)──→ 近似正弦波 ──→ PI core 矢量求和",
        ha="center", fontsize=9.2, color="#b35900", fontweight="bold")

# ---------------- 输入 ----------------
box(2, 44, 14, 14, "CMN 公共时钟\nCKI_I / IB / Q / QB\n_CMOS\n(rail-to-rail VDD)", "in",
    fs=8.5, weight="bold")

# ---------------- slope_ctrl ----------------
container(19, 32, 30, 34, "slope_ctrl_core (方波 → 三角波)", "slope")
box(21, 52, 26, 10, "三态反相器 (EN_LF 可关断)\n→ X4 反相器驱动级", "slope", fs=8.3)
box(21, 41, 26, 9, "slope_ctrl_unit ×4 (方波→三角波)\nPATH_SEL<2:0> 独热码三选一支路\n越高位: 串联传输门越多, RC 越大, 边沿越缓", "slope", fs=7.4)
box(21, 34, 26, 5.5, "I/IB · Q/QB 交叉耦合反相器对\n(强制互补 / 校正占空比)", "slope", fs=7.6)

# ---------------- Pre-buffer ----------------
container(52, 36, 22, 26, "LF Pre-Buffer", "pre")
box(54, 49, 18, 9, "I 路 CML 级 (三角→正弦)\n541.7 Ω 电阻负载带限", "pre", fs=7.8)
box(54, 38, 18, 9, "Q 路 CML 级\n(结构同上)", "pre", fs=8.0)

# ---------------- LF core (图5 实测结构) ----------------
container(78, 32, 34, 30, "PI LF Core (电流域矢量求和)", "core")
box(79.5, 34, 9, 23, "cfmom\nAC 耦合 ×4\n高通下限\n≈100 MHz\n+VCM 再偏置\n23.57 kΩ\n(PD 可断)", "core", fs=6.8)
for i, q in enumerate(["+I\nIBN_A", "\u2212I\nIBN_B", "+Q\nIBN_C", "\u2212Q\nIBN_D"]):
    box(90 + i * 5.4, 45, 4.5, 10, q, "core", fs=6.8)
box(90, 34, 20.5, 8,
    "共享电阻负载 300 Ω → VDD\nGP/GN 电流求和:\nV ∝ (wA−wB)·I + (wC−wD)·Q",
    "core", fs=6.8)
arrow(89.2, 50, 90.4, 50, "", color="#c07817", lw=1.3)
arrow(100.2, 44.4, 100.2, 42.6, "", color="#c07817", lw=1.3)

# ---------------- Post-buffer ----------------
container(116, 40, 20, 20, "LF Post-Buffer", "post")
box(118, 44, 16, 11, "CML 输出级\n541.7 Ω 电阻负载", "post", fs=8.3)

# ---------------- 输出 ----------------
arrow(136, 50, 143, 50, "", color="#333", lw=2.2)
ax.text(151, 50, "OP / ON\nVppd ≥ 500 mV\n@ 理想 20 fF", ha="center", va="center",
        fontsize=8.5, fontweight="bold")

# ---------------- 主信号流 ----------------
arrow(16, 51, 19, 51, "", color="#2c6fad", lw=2.0)
arrow(49, 53, 52, 53, "CKO_I/IB", color="#b33636", lw=1.8, dy=2.0)
arrow(49, 43, 52, 44, "CKO_Q/QB", color="#b33636", lw=1.8, dy=-2.2)
arrow(74, 53, 79, 52, "CKI/CKIB", color="#1e7d4f", lw=1.8, dy=2.0)
arrow(74, 42, 79, 44, "CKQ/CKQB", color="#1e7d4f", lw=1.8, dy=-2.2)
arrow(111, 38, 116, 47, "GP / GN", color="#c07817", lw=2.0, dx=1, dy=2.0)

# ---------------- 与 MHF 的差异注释 ----------------
ax.text(72, 27.5,
        "与 MHF Path 的架构差异:  ① 输入为 CMOS 方波 (非 CML)，靠 slope_ctrl+pre-buf 两级整形逼近正弦保证插值线性度"
        "   ② 全程纯电阻负载 (pre/post 541.7 Ω, core 300 Ω)，无电感 peaking / 无频段切换   ③ 单一 EN_LF 使能，无 MF/HF 分档",
        ha="center", fontsize=8.4, color="#666", style="italic")

# ---------------- IDAC ----------------
box(112, 66, 40, 11, "IDAC (LF 支路, 经 EN_LF 电流 MUX 选路)\nIBN_A..D = 7-bit 温度计, 满幅 2 mA 同 MHF (LF 用~1 mA)\nIBN_PRE/POST_BUF 1 mA · 片内 1:10 镜像 (暂定)",
    "idac", fs=7.6, weight="bold")
arrow(120, 66, 63, 62.5, "IBN_PRE_BUF_I/Q", color="#555", lw=1.5, dx=-12, dy=2.4)
arrow(128, 66, 100, 56, "IBN_A..D (插值权重)", color="#555", lw=1.7, dx=-2, dy=2.4)
arrow(140, 66, 126, 55.5, "IBN_POST_BUF", color="#555", lw=1.5, dx=6, dy=2.4)

# ---------------- 控制轨 ----------------
box(19, 14, 117, 6.5,
    "全局控制:  EN_LF (高有效) → PD/PDB 链: 关断三态反相器 · 断开 VCM 再偏置 · IBN_A..D 拉地\n"
    "PATH_SEL<2:0> (独热码三选一斜率档, 默认 000 = 全关, PVT 补偿)  ·  VCM = 350 mV (LF 专用)  ·  上层 EN_MHF / EN_LF 选路",
    "ctrl", fs=8.0)
for xc in (34, 63, 95, 126):
    arrow(xc, 20.5, xc, 25.5, "", color="#9a8a00", lw=1.4)

import os
out = os.path.join("docs", "figures", "pi_lf_architecture.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
fig.savefig(out, bbox_inches="tight", facecolor="white")
print("saved:", os.path.abspath(out))
