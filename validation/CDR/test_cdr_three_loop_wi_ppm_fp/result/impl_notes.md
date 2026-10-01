# 定点 ppm 三环套件 实现说明与验收结论

生成日期: 2026-10-01
分支: `feat/ppm-fixed-point`
对应结果: `result/cdr_three_loop_ppm_{p100,p0,m100}/`

## 1. 验证目标与整体结构

把 `src/CDR` 的 CDR+dlev+CDR-FFE 三环内核定点化，并验证在 **−100 / 0 / +100 ppm**
频偏下的全相位捕获行为与浮点参考一致。

被测对象是 `src/CDR/+cdr_fx/` 包：与浮点参考**公开面同形状**的平行定点类
（`cdr_voter` / `cdr_loop` / `cdr_pi` / `dlev_loop` / `cdr_ffe` / `cdr_ffe_loop` /
`loop_monitor` / `cdr_top`）。浮点参考 `src/CDR/*.m` 一个字都没改，既有验证的
复现性完全保留。

**本套件由 `test_cdr_three_loop_wi_ppm_v1` 整目录派生**（`tools/build_fp_suite.py`），
除以下三处外与 `_v1` 的 runner **逐字相同**：

| 位置 | 改动 |
|---|---|
| `cfg = cdr_top.defaultConfig()` | → `cdr_fx.cdr_top.defaultConfig()` |
| `top = cdr_top(cfg)` | → `cdr_fx.cdr_top(cfg)` |
| `cfg.FfeGateFreqWindowBlocks` | → 三个 EWMA 系数 `FfeGateAlphaFast/Slow/Mad` |

保持逐字相同是刻意的：这样浮点与定点两条路径的任何结果差异，都只可能来自
定点化本身，而不是 runner 的实现分歧。

## 2. 关键实现要点与设计取舍

### 2.1 存储策略：double + 显式量化，而非 `fi` 对象

每个节点都在其声明格式上显式量化并饱和。本设计最宽的乘积是
FFE 系数 `(1,24,22)` × ADC 码 `(1,7,0)` = 31 位，6 抽头求和 34 位，远在 double
的 53 位尾数之内，因此与整数运算**逐位等价**，而速度与浮点相同。

这不是偷懒：验收需要 15000 block × 8 相位 × 3 个 ppm 点，`fi` 对象会慢 10~100 倍，
长跑不可行。实测本套件单个 ppm 点约 80 s，浮点约 55 s，只慢 1.45 倍。

### 2.2 字长由实测定，不靠猜

全部取自 `test_cdr_fixed_point` 的范围普查（32 相位 × 15000 block × 3 工况）。
格式集中在 `src/CDR/+cdr_fx/fxfmt.m`，是 `docs/CDR_FIXED_POINT.md` §4 的可执行版本。

最吃紧的一处：**FFE 系数 LMS 累加器需要 22 位小数**（实测最小增量 3.125e-6），
比凭经验估的 20 位多 2 位。按 20 位做会让单块更新量小于 LSB 而被丢弃，
累加器进入死区 —— 环路看着收敛实则冻结，波形上几乎看不出来。

### 2.3 四处结构性改写

| # | 改动 | 性质 |
|---|---|---|
| 1 | voter 除法折进 `Kp`/`Ki`（8.0→0.125, 0.03→4.6875e-4） | 严格等价，省一个除法器 |
| 2 | SNR 门控由 dB 换成功率比比较 | 判决等价，对数不进硅 |
| 3 | 频率态门控由 2048 深滑窗 mean/std 改为三条 EWMA | 见 §2.4 |
| 4 | slicer 与 dLev 的归属判断统一用窄值 `(1,9,2)` | 必须，见 §2.5 |

### 2.4 频率态门控改用指数平均（用户 2026-10-01 要求）

原方案在硅里要 2048 深缓冲 + 宽加法树 + 54 位平方和累加器。改为三个寄存器：

```
ewmaFast (α=1/64)   快速跟随
ewmaSlow (α=1/512)  慢速基准
ewmaMad  (α=1/256)  |x − ewmaSlow| 的指数平均，替代标准差
```

判据与原窗口判据一一对应：

| 原判据 | EWMA 版 |
|---|---|
| 尾窗分半均值差小 | `\|ewmaFast − ewmaSlow\| <= MeanHalfDiffTol` |
| 尾窗 std 小 | `ewmaMad <= StdTol` |
| 与期望速率匹配 | `\|ewmaSlow − ExpectedRate\| <= RateTol` |

三个 α 都必须是 2 的负幂，这样 EWMA 就是「移位-减-加」。面积与功耗低一个
数量级以上，并且不再需要把窗口凑成 2 的幂（原方案 2000→2048 会改变判据数值）。

MAD 与 std 的关系：高斯下 MAD ≈ 0.798·std，所以沿用原 `StdTol` 时判据略严。
这是刻意的保守选择 —— 早触发正是 2026-09-26 那次 −100 ppm 全相位失败的根因。

### 2.5 两个必须避开的陷阱（都实际踩到过）

**① FFE LMS 的符号约定。** 浮点 `cdr_ffe_loop.updateSsLmsFast` 用的是
`+StepSize * gradient`，配合 `cdr_top` 传入的 `error = decision − ffeOutput`。
最初按教科书 `e = x − d` 对应的 `−StepSize` 写，结果 **LMS 反向收敛**：

| | 错误符号 | 修正后 | 浮点 |
|---|---|---|---|
| FFE pre1 抽头 | **+0.497** | −0.224 | −0.226 |
| 末段 SNR | **9.65 dB** | 24.12 dB | 23.57 dB |
| 第一级门控 | **从未触发** | block 370 | block 388 |

注意失效形态：环路**仍然在跑**，freqState 也接近期望值，只是眼睛打不开。
单看 freqState 会误以为没问题。

**② slicer 与 dLev 必须用同一个截断值。** `dlev_loop` 用精确相等判内外环归属
（`abs(d) == DLevInner`）。dLev 存在 `(1,23,16)` 宽累加器里，slicer 用
`(1,9,2)` 窄值。若比较时一边用累加器一边用截断值，这个 `==` 永远不成立 ——
内外环归属全错、误差恒零、dLev 环静默死掉，而且波形上看不出来。
本实现对外暴露 `DLevInnerSlice` / `DLevOuterSlice` / `ThresholdSlice`，
内部比较一律用它们。

### 2.6 环路参数调整：只改了一处取整模式

用户允许"自行完成定点化的环路参数调整（如有必要）"。实际**没有改任何环路
增益、步长或阈值** —— `Kp`/`Ki`/`MaxDeltaCode`/`FrequencyLimit`/dLev 三档步长/
FFE 三档步长/门控阈值全部沿用浮点默认值。

唯一的改动是积分支路的**取整模式 `floor` → `round`**：

| | floor | round |
|---|---|---|
| 0 ppm 残余 freqState | **−0.0035**（约 115 LSB） | **−0.00008 ~ +0.00009** |
| +100 ppm freqMean | −0.8227 | −0.8193 |

`floor` 每次累加引入 −0.5 LSB 的系统偏置，积分器会把它一直累积到 PD 产生反向
偏置来平衡，最终表现为采样相位偏移。RTL 里 `round` 就是"加半个 LSB 再截断"，
只多一个常数加法器，代价可忽略。

## 3. 本次运行配置

- 全默认：`NumBlock=15000`，`StartPhaseStep=16`（8 个起始相位 0:16:112）
- `CosimDir='channel_ctle_cosim_prbs22'`，PRBS22 完整周期缓存
- `FreqOffsetPpm` 分别取 +100 / 0 / −100
- 无参运行即可复现

## 4. 关键结果与结论

**三个 ppm 点全部 8/8 锁定，`AllPhaseLock=1`。**

| ppm | 定点 freqMean 范围 | 浮点 freqMean 范围 | 理论期望 |
|---|---|---|---|
| +100 | −0.81931 ~ −0.81912 | −0.81934 ~ −0.81915 | −0.81920 |
| 0 | −0.00008 ~ +0.00009 | −0.00008 ~ +0.00006 | 0 |
| −100 | +0.81915 ~ +0.81924 | +0.81917 ~ +0.81926 | +0.81920 |

**定点与浮点的 freqMean 差异在 1e-5 量级**，比与理论期望值的差距还小。

逐节点溢出计数**全为 0**（`cdr_top.overflowReport()`），说明字长留有余量，
没有任何节点在三个工况下饱和。

单相位对照（+100 ppm，start phase 0，4000 block）：

| 量 | 定点 | 浮点 |
|---|---|---|
| freqState 尾段 std | **0.00222** | 0.00459 |
| dLev inner / outer | 10.624 / 31.628 | 10.572 / 31.703 |
| 末段 SNR | 24.12 dB | 23.57 dB |
| FFE 末系数 | [0.035, −0.224, 1, −0.106, 0.092, −0.007] | [0.036, −0.226, 1, −0.101, 0.089, −0.005] |
| 第一级门控块号 | 370 | 388 |

定点的尾段 std 反而比浮点小一半 —— 量化栅格抑制了小幅抖动。

## 5. 复现方法

```matlab
cd validation/CDR/test_cdr_three_loop_wi_ppm_fp
setup_cdr_three_loop_wi_ppm_fp_paths();
cdr_three_loop_ppm();                                  % 默认 +100 ppm
cdr_three_loop_ppm('FreqOffsetPpm', 0);
cdr_three_loop_ppm('FreqOffsetPpm', -100);
cdr_three_loop_ppm('FreqOffsetPpm', 100, 'SaveOutputs', false);   % 只看结论不落盘
```

前提是 `test_cdr/result/channel_ctle_cosim_prbs22/channel_ctle.mat` 缓存存在
（已被 `.gitignore` 排除，需本地先跑过 cosim 脚本）。

套件重新派生：`python tools/build_fp_suite.py`（会整目录重建，`result/` 保留）。

## 6. 遗留与下一步

1. **`PendingCode` 钳位值 ±1024 是代理自选的**，待复核。本三组工况下 `PendingCode`
   从未接近钳位（溢出计数为 0），所以当前验收不受影响；但 +120~+130 ppm 的
   slew 饱和场景尚未在定点下测过，钳位值与 `SlewSatPendingTol` 的配合需要
   在那个区间单独验证。
2. **离线静态判据仍是浮点**（`detectFrequencyStateLock` / `detectRotationPeriodLock`）。
   按用户 2026-10-01 的界定，只有 SNR 与频率态两个**在线**检测器算硅，
   离线判据属测试台，不需要定点化。
3. 尚未做**判决级位精确对拍**（`PhaseDecision` / `DataSymbol` / `ErrorBit` 逐块
   比对）。当前验收是轨迹级容差。位精确对拍需要浮点与定点在同一激励下逐块
   比较，是下一步最有价值的加固。
4. 定点下的 ppm 牵引范围尚未重测。浮点实测负向 −30 ppm、正向 +110 ppm，
   定点是否相同需要单独扫描。
