# cdr_dlev_cdrffe_sslms_v4 实现说明与运行记录

生成日期: 2026-09-23
入口: `validation/CDR/test_cdr_dlev_cdrffe/src/cdr_dlev_cdrffe_sslms_v4/cdr_dlev_cdrffe_sslms_v4.m`
结果目录: `validation/CDR/test_cdr_dlev_cdrffe/result/cdr_dlev_cdrffe_sslms_v4/`

--------------------------------------------------------------------------------
## 1. 验证目标与整体结构

v4 与 v3 的**算法完全相同**，区别只在归属：v3 把三环、判决器、FFE 窗口和时序调度
全部写在验证脚本里；v4 把这些收敛进可复用的 `src/CDR/cdr_top`，脚本退化为薄壳。

本脚本要验证的是两件事：

1. `cdr_top` 的 code 域 config 模式能逐块位精确复现 v3 的闭环行为；
2. 用该顶层做全相位闭环实验时，相位环 / dlev 环 / CDR-FFE 环仍能协同收敛。

被测对象与职责边界：

```
v4 脚本负责                              cdr_top(config) 负责
────────────────────                     ──────────────────────────────
CTLE 缓存读取与分析段裁剪                cdr_ffe + pending 窗口(1-block 死时间)
ti_adc_top 构造与量化                    单判决器 cdr_top.slicePam4
物理 lane -> 时间序重排                  cdr_pd (MMPD, transitionFilter=true)
绝对 UI 寻址 base+(k-1)*64+uiSlip        cdr_voter ('mean', 除数 auto)
多起始相位扫描                           cdr_loop + cdr_pi
trace 收集 / 统计 / 绘图 / 落盘          dlev_loop (SS-LMS)
                                         cdr_ffe_loop (SS-LMS)
                                         loop_monitor（FFE 写门控 + dLev 换挡）
```

**`cdr_top` 全文不引用任何 ADC 符号**，采样与波形寻址始终在脚本侧。

验证判据（沿用 v3 口径，未放宽）：

- PI 锁定：末 2000 blocks 众数中心 C，±3 inclusive，非中心到达 C 或严格跨过 C 计 1 次，
  越界清零，>=51 次判锁（`detect_pi_center_touch_lock`）。
- `AllPhaseLock` = 全部起始相位锁定 **且** 各自锁定码距公共锁定相位 <= 3。
- dlev 一致性：各相位终值内/外环 spread <= 2 * 1.0 code。
- FFE 一致性：各相位终值系数 spread <= 2 * 0.01；pre1/post1 归一化光标 |.| <= 0.02。

--------------------------------------------------------------------------------
## 2. 关键实现要点与设计取舍

### 2.1 一个 block 的环路死时间（物理口径）

CDR FFE 需要下一块的 `PreTapCount`(=2) 个前光标样本，所以第 k 块要等第 k+1 块采样
完成后才能均衡。`cdr_top` 内部用 pending 缓冲实现该流水：

```
phase[k+1] == phase[k]
phase[k+2] == phase[k] + delta[k]
```

`processBlock` 在 pipeline 未填满时返回 `HasOutput=false`；`flush()` 用零 future
样本处理最后一个 pending 块。脚本因此写成 `for k = 1:numBlocks+1`，最后一次调 `flush`。
旧的组件注入路径（BBPD）保持原来的零延迟语义，两者不可混用。

### 2.2 边界块只有部分有效样本

首个处理块缺 `PostTapCount`(=3) 个过去样本，末块缺 `PreTapCount`(=2) 个未来样本，
因此有效样本数为 61 / 62 / 64。处理方式与 v3 一致：

- 无效样本**直接丢弃，不补零**；
- 相位环照常更新（voter 用 `'auto'` 除数，除的是实际有效样本数 61/62/64）；
- dlev 与 FFE 只在满 64 个有效样本时更新（两个引擎都按固定 `BlockSize` 归一化）。

### 2.3 单判决器与 MMPD 输入天然符号化

`cdr_top.slicePam4` 用 dlev 当前内/外电平与门限在 code 域判一次，产出共享的
`(d, e)`，再派生 0-3 符号与误差符号位。`cdr_pd.mmpd` 的入参本来就只接受 0-3 与 0/1，
幅度信息没有入口——所谓 "SS-MMPD" 就是这条路径本身，不存在第二条数值路径。
`Detector='ssmmpd'` 只是别名，构造时归一成 `'mmpd'`。

### 2.4 FFE 写门控：freeze vs pvt-track

因果检测器 `loop_monitor`（原 `ffe_freeze_monitor`，现同时承载 FFE 写门控与 dLev
换挡两个因果状态机）用**本块采样时**的 unwrapped PI code
(`uiSlip*128 + codeWrapped`)，在本块输出已算出、任何系数写入之前更新一次。触发后：

- `FfeGateMode='freeze'`：永久禁止系数写入，但 SS-LMS 原始增量仍照常计算并记录
  （`FfeRawDeltaTrace` / `FfeProposedCoefficientTrace` 继续有值，
  `FfeAppliedDeltaTrace` / `FfeWriteAppliedTrace` 保持 0）。
- `FfeGateMode='pvt-track'`（默认）：不停写，把 FFE 步长一次性降到
  `FfeStepSizePvtTrack`，之后只以极窄带宽跟踪 PVT 慢漂。

两种模式都不影响相位环与 dlev 环。

### 2.5 mu 单次降档

`dlevSettled = blockIndex > DlevSettleWindow && |DLevOuter[k] - DLevOuter[k-W]| <= tol`。
`~SettleDone && dlevSettled` 时把 dlev 与 FFE 同时从捕获档降到稳态档，只触发一次。
**不以相位锁定为门控**：捕获档下相位会自由跑，锁定门控会造成死锁（见 2026-09-21 决策）。

该判据由 `loop_monitor` 的 dLev settle 检测器持有（`recordDlevOuter`/`updateDlevSettle`，
历史用长度 `DlevSettleWindow+1` 的环形缓冲，内存不随块数增长）。monitor 只判决、
返回是否触发，`cdr_top` 收到后才施加 `setStepSize`——策略与数据通路分离。

### 2.6 相对 v3 删除的内容

训练模式整条路径被删除：golden TX 缓存读取、`channelMainCursorUi` 主光标延迟补偿、
`FfeTrainingBlocks` / `FfeTrainingReferenceMode` / `FfeTrainingOuterRef` /
`FfeTrainingInnerRef`、训练 trace、训练后直方图第一排。
因为 v3 当前默认 `FfeTrainingBlocks = 0`，这些分支从未执行，**删除是位精确的**。
FFE 的期望信号恒为共享判决器给出的 live 判决（由 live dlev 电平导出）。

`PdOffset` 也未迁移：v3 解析并写入 result 但从未参与任何更新方程，属于死旋钮。

--------------------------------------------------------------------------------
## 3. 本次运行配置

无参默认（`cdr_dlev_cdrffe_sslms_v4()`）：

| 项 | 值 |
|---|---|
| 码型缓存 | `channel_ctle_cosim_prbs22`，128 samples/UI，完整 PRBS22 周期 |
| 块数 / 起始相位 | `NumBlock=15000`，`StartPhaseStep=16` => 8 个相位 `0:16:112`（注意 v3 默认仍为 30000，两者已分叉，做 v3/v4 对比必须显式传 `NumBlock`）|
| ADC | 64 lane / 8 SAR-per-TAH / 7 bit / 满量程 ±4 |
| CDR FFE | 6 抽头 `-2:3`，planB 冷启动 `[0 0 1 0 0 0]`，mask `[1 1 0 1 1 1]` |
| 相位环 | Kp=8，Ki=0.03，积分限幅 ±4，**MaxDeltaCode=1**（PI 每次更新只动 1 码，物理口径），PI 7bit 理想 LUT |
| PD | MMPD，`transitionFilter=true`（仅 0<->3 / 1<->2 对称跳变），polarity=+1 |
| voter | `mean`，除数 `auto` |
| dlev | 初值 inner=16 / outer=48，mu 0.5 -> settle 0.1，settle 窗 16 / 容差 0.5 |
| FFE mu | 0.004 -> settle 0.0002；pvt-track 档 0.0002 |
| FFE gate | enable=true，mode=`pvt-track`，500 次众数 / 100 次事件 / 带宽 ±3，起始块 1 |
| 眼图 | enable=true，2048 UI |

--------------------------------------------------------------------------------
## 4. 关键结果与结论

### 4.1 v3 <-> v4 位精确等价（主判据，通过）

三组配置下逐字段对比，**26 个字段全部 max abs diff = 0**：

| 组 | 配置 | 结果 |
|---|---|---|
| gate | NumBlock=1500，相位 [20 64]，gate 100/20，`pvt-track` | 26/26 = 0 |
| freeze | NumBlock=1500，相位 [20 64]，gate 100/20，`freeze` | 26/26 = 0 |
| prod | NumBlock=6000，相位 [20 64]，gate 500/100，`pvt-track` | 26/26 = 0 |

对比字段涵盖 `PhaseCodeTrace` / `UiSlipTrace` / `UnwrappedPhaseTrace` /
`TimingErrorTrace` / `DeltaCodeTrace` / `EdgeCountTrace` / 三条 dlev trace /
`FfeCoeffTrace` / `FfeRawDeltaTrace` / `FfeAppliedDeltaTrace` /
`FfeProposedCoefficientTrace` / `FfeAdaptationCalculatedTrace` /
`FfeWriteAppliedTrace` / `FfeFrozenTrace` / `FfeFreezeBlock` /
`FfeFreezeCenterUnwrapped` / `FfeFreezeEventCount` / `FfeFrozenCoefficients` /
`LockedFlag` / `LockedPhaseCode` / `CommonLockPhase` / dlev 终值 / FFE 终值系数。

gate 组中 start phase 64 在 block 1455 触发门控，v3 与 v4 触发块号一致。

### 4.2 无参默认全相位运行（通过）

耗时 134.1 s。

- **锁定：8/8，`AllPhaseLock = 1`**，公共锁定相位 113，spread 4，
  各相位众数 `[111 112 113 114 111 114 115 112]`。
- 首次捕获块 `[3217 3445 4071 5434 3770 4494 3748 2544]`；
  绘图选中"首次捕获最慢"的起始相位 48（first capture block 5434）。
- PVT-track 门控 8/8 全部触发，触发块 `[6558 10960 9064 9328 7474 15982 12356 6013]`。
- dlev 一致性 **通过**：内环均值 10.019、外环均值 30.286。
- 末 2000 block 窗口内中心事件数 72..87，均 >= 51。

### 4.3 未通过项（如实记录，未调参）

- `FfeConsistent = 0`：各相位终值系数最大 spread 0.04466 > 阈值 0.02。
- `FfeConstraintHeld = 0`：pre1 = +0.0051（合格），post1 = -0.0218，略超 0.02 容差。
- dlev 对离线真值偏差：内环 -2.231、外环 -6.431 code。

这三项与 v3 同参数下的表现同源（v4 与 v3 位精确等价，因此不是 v4 引入的退化），
属于 SS-LMS 稳态 misadjustment 与长时间常数弛豫的已知边界，**不要与相位锁定混同**。
本次任务未做任何调参。

### 4.4 收敛性质判定：真抖动，非缓慢漂移（2026-09-23 新增）

整数 PI code 会把亚码运动藏起来，慢漂与真锁在相位码上都呈阶梯状。为可判，
`cdr_top` 每块额外导出环路滤波器**量化前**的连续量，v4 存为四条 trace：

| trace | 含义 | 锁定特征 | 漂移特征 |
|---|---|---|---|
| `LoopControlTrace` | `Kp*phaseError + FrequencyState`，相位速度需求 [code/block] | **长窗均值≈0**，围绕 0 变号 | **持续非零直流** |
| `LoopFrequencyStateTrace` | 积分态 = 频偏估计 [code/block] | 稳定在≈0 或常数 | 单调爬升 |
| `LoopCodeResidueTrace` | 亚码余量 ∈(-1,1) | 正负两侧都出现 | 锁在同一侧 |
| `LoopPendingCodeTrace` | 被 `MaxDeltaCode` 限住的整数积压 | 捕获后恒 0 | 长期非零=在追赶 |

> ⚠️ 判据强弱必须分清：**`LoopControl` 的长窗均值与 `FrequencyState` 的稳态值才是判据**。
> `CodeResidue` 的**幅度范围 (-1,1) 是结构性的、恒成立**，它填满该区间**不能**作为收敛证据；
> 它唯一的信息量在**符号分布**——单向漂移时 `residueAccum = residue + v` 恒同号，
> `fix()` 向零截断会把它锁在同一侧。故 `CodeResidue` 只作旁证，不作主判据。
> 同理 `rawDeltaCode` 与 `deltaCode` **都是整数**（`cdr_loop.m:86,88`），
> 全链路只有 `control` 与 `CodeResidue` 是小数，所以"看连续量抖不抖"只能看 `LoopControl`。

无参默认跑（15000 blocks / 8 相位，`MaxDeltaCode=1`）末 2000 blocks 实测：

| start | mean(control) | FreqState(end) | netUIdrift |
|---|---|---|---|
| 0 | -3.62e-06 | 4.203e-03 | 0.0000 |
| 16 | 2.157e-04 | 5.571e-03 | 0.0078 |
| 32 | 4.355e-05 | 4.740e-03 | 0.0000 |
| 48 | -2.056e-05 | 3.857e-03 | -0.0078 |
| 64 | 3.080e-04 | 5.248e-03 | -0.0078 |
| 80 | -4.181e-04 | 1.490e-03 | 0.0000 |
| 96 | 3.532e-04 | 6.131e-03 | -0.0078 |
| 112 | -2.367e-04 | 4.218e-03 | -0.0078 |

结论：相位速度需求 ~1e-4 code/block（折合 **≈0.05 ppm**，等于零）；积分态稳定在
~5e-3 无爬升；末段净漂移 0 或 ±0.0078 UI（恰为 1 个 PI 码）。
**判定：三环收敛为真锁定（限幅环抖动），不是缓慢漂移。**

`LoopPendingCodeTrace` 统计（`MaxDeltaCode=1`）：全局 `max|PendingCode| = 1`，
仅 **5/120000 个块**（0.004%）出现过积压，且全部在捕获期，最后一次在 block 5432。
说明稳态下环路需求几乎从不超过 1 code/block，**限幅不是收敛的制约因素**。

可复用判据（末 2000 blocks）：`|mean(LoopControl)| < 1e-3` 且
`sign-flip(非零 deltaCode) > 0.4` 且 `|netUIdrift| < 0.05 UI`。

### 4.5 已知边界

- 8 个起始相位是默认 `StartPhaseStep=16` 的结果，不等于 32 相位全扫描结论。
- `pvt-track` 模式下 FFE 一直在写（只是带宽极窄），因此终值系数仍受长尾弛豫影响。
- 眼图基于选中相位的固定抽头重放，不是在线逐块眼。

--------------------------------------------------------------------------------
## 5. 复现方法

无参默认（上面 4.2 的配置）：

```matlab
addpath(fullfile(repoRoot,'validation','CDR','test_cdr_dlev_cdrffe'));
setup_cdr_dlev_cdrffe_paths();
result = cdr_dlev_cdrffe_sslms_v4();
```

常用切换：

```matlab
% 短跑冒烟（约 40 s）
cdr_dlev_cdrffe_sslms_v4('NumBlock',1200,'StartPhaseList',[20 64]);

% 32 个起始相位全扫描
cdr_dlev_cdrffe_sslms_v4('StartPhaseStep',4);

% 切到经典永久冻结
cdr_dlev_cdrffe_sslms_v4('FfeFreezeMode','freeze');

% 关闭门控，让 FFE 一直以稳态 mu 自适应
cdr_dlev_cdrffe_sslms_v4('FfeFreezeEnable',false);

% 不落盘、不画眼图（做等价性对比时用）
cdr_dlev_cdrffe_sslms_v4('SaveOutputs',false,'EyeDiagramEnable',false);
```

v3 <-> v4 等价性复现：用同一组 name/value 分别调 `cdr_dlev_cdrffe_sslms_v3` 与
`cdr_dlev_cdrffe_sslms_v4`（v3 需额外的 `TxFile` 缓存存在，v4 不需要），
再对 4.1 列出的字段逐个比 `max(abs(a-b))`。

相关单元回归：

```matlab
test_cdr_top             % 旧组件注入路径 6/6
test_cdr_top_configured  % 新 config 模式 11/11
test_cdr_voter           % 7/7
test_cdr_loop            % 10/10
test_loop_monitor         % 11/11
test_cdr_validation_paths
```

--------------------------------------------------------------------------------
## 6. 输出清单

| 文件 | 内容 |
|---|---|
| `cdr_dlev_cdrffe_sslms_v4_result.mat` | 完整 result 结构体（含全部 trace） |
| `cdr_phase_convergence.fig` | 选中相位的相位收敛，标众数锁定码/S-curve 参考相位(虚线)、首次捕获块(红)与 FFE 门控块(绿) |
| `cdr_locked_phase_vs_start_phase.fig` | 锁定相位码 vs 起始相位，蓝圈通过/红叉失败/公共锁定码虚线 |
| `dlev_convergence.fig` | 选中相位 dlev 内/外环收敛，标内外参考电平、初值电平、首次捕获与门控块 |
| `cdr_ffe_convergence.fig` | 选中相位各自由抽头 tiled 收敛，每抽头标离线参考值、捕获块、门控块与 pre/post 命名 |
| `cdr_ffe_output_histogram.fig` | 收敛稳态尾段 2048 个 FFE 输出 code 直方图，叠加离线参考电平(灰)与在线收敛 dlev 电平(红)+图例 |
| `cdr_total_path_ui_response.fig` | channel->CTLE->ADC->FFE 总通路单位 UI 响应，主光标红色高亮、每游标数值文本标注、pre1/post1 目标 0 参考线 |
| `cdr_loop_dither_vs_drift.fig` | **抖动 vs 漂移诊断**（3 联）：LoopControl（量化前相位速度需求，附末段均值线）/ FrequencyState（积分态）/ CodeResidue（亚码余量，±1 限幅）|
| `cdr_ffe_eye_at_freeze_2048ui.fig` | 门控触发点的 2048 UI 眼图 |
| `cdr_ffe_eye_final_2048ui.fig` | 仿真末段 2048 UI 眼图 |
| `cdr_ffe_eye_freeze_vs_final.fig` | 两张眼图并排对比 |
| `first_capture_summary.csv` | 各相位锁定标志/众数/首次捕获块/末窗事件数 |
| `ffe_freeze_summary.csv` | 各相位门控触发块/中心/事件数/复位数 |

--------------------------------------------------------------------------------
## 2026-09-28 追加：FFE 写门控从 center-touch 迁移到 freq-state

**背景**：`cdr_top` 于 2026-09-28 删除了 `FfeGateCriterion='center-touch'` 判据，
唯一判据改为 `'freq-state'`（默认值也从 `'center-touch'` 翻成 `'freq-state'`）。
v4 此前依赖 cdr_top 内部的 center-touch 门控来冻结 FFE：读 `Monitor.Frozen`
及 `FreezeBlock/CenterUnwrapped/ModeOccurrences/EventCount/ResetCount`。删判据后
这些恒空，v4 冻结上报会失效，故本次把 v4 的**冻结门控**迁移到 freq-state。

**改动（`cdr_dlev_cdrffe_sslms_v4.m`）**：
- 新增 cfg 配置：`FfeGateFreqWindowBlocks=min(FfeFreezeWindowBlocks,numBlocks)`、
  `FfeGateFreqExpectedRate=0`（v4 是 0 ppm）、容差
  `FreqMeanHalfDiffTol=0.03 / FreqStdTol=0.08 / FreqRateTol=0.12`、`MinBlock=1`。
  取值与 ppm 套件 0-ppm 情形一致。新增同名 options 默认（窗口默认 2000）。
- 冻结检测由读 `Monitor.Frozen`/`FreezeBlock` 改为读 `Monitor.FreqGateDone`/
  `FreqGateBlock`。`FfeFrozenCoefficients` 仍取 `GatedCoefficients`。
- `FfeFreezeCenterUnwrapped/Wrapped` 改记冻结当块的 tracked eye 相位（freq-state
  门控无"模式中心"概念），供眼图标注。
- `FfeFreezeModeOccurrences / FfeFreezeEventCount / FfeFreezeResetCount` 是
  center-touch 专有计数，freq-state 下**退役为 NaN**（result 字段与
  `ffe_freeze_summary.csv` 的 CenterOccurrences/FreezeEvents/SearchResets 列保留但恒 NaN）。
- 上面仍设的 `FfeGateMin*/BandHalfWidth` 只用于构造 loop_monitor 里保留但休眠的
  center-touch 机制（供旧 MAT 离线回放），不再决定 v4 冻结。
- **锁定 verdict 不变**：仍用 `detect_pi_center_touch_lock`（独立 helper，机制与
  cdr_top 门控无关），v3/v4 共用。

**结论变化（重跑，默认 8 相位 / StartPhaseStep=16 / NumBlock=15000）**：
- 8/8 相位 locked（锁定 verdict 不变），8/8 FFE 经 freq-state 门控冻结。
- 冻结块整体**变晚**：`FreezeBlock` 落在 `[2000, 2218]`（freq-state 需 2000-block
  平坦窗口），而历史 center-touch 冻结约在 block 1214–1465。冻结中心
  `FreezeCenter ∈ [109, 123]`。这是判据切换的预期结果，非环路变差。
- 全部 result 图/CSV 已随之重生成（含 `cdr_ffe_eye_at_freeze_2048ui.fig` 与
  `cdr_ffe_eye_freeze_vs_final.fig`，冻结窗口起点改用 freq-state 触发块）。

**复现**：无参默认 `cdr_dlev_cdrffe_sslms_v4()`；快速冒烟
`cdr_dlev_cdrffe_sslms_v4('NumBlock',4000,'StartPhaseList',[16 64],'SaveOutputs',false,'EyeDiagramEnable',false)`。
