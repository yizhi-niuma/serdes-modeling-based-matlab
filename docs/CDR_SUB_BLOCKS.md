# CDR Sub Block 契约参考

> 本文件是 `src/CDR/` **当前源码**的契约参考（接口、算法、边界、已知缺口）。
> 刷新日期：2026-09-30。分支 `codex/mmpd-weighted-transitions-v1`。
>
> ⚠️ **本文描述的是「工作区状态」，不是任何已提交的 commit。**
> 基线 = `HEAD (f4744a4)` **加上当时未提交的工作区改动**，其中包括一次
> **进行中的 `loop_monitor` 重构**（构造器由 4 参改为零参、`updateFfeGate`
> 被删除，未提交改动约 438 行）。§13 记录的绝大部分「缺口」都是这次
> 半成品重构的直接产物。**该重构一旦提交或回退，§13 与 §14 立即失效，必须重跑重写。**
>
> 口径：**以源码为唯一事实来源**。凡是源码注释、旧文档、旧结论与源码冲突的，以源码为准，
> 并在 §13「已知缺口」里显式记录冲突，不做静默修正。

## 1. 模块总表

`src/CDR/` 共 **9 个 class**，3038 行：

| # | 文件 | 行数 | 角色 | 层 |
|---|---|---|---|---|
| 1 | `cdr_pd.m` | 260 | 相位检测器：BBPD / MMPD（PAM4 判决+误差域） | 时序链 |
| 2 | `cdr_voter.m` | 164 | 块级 PD 输出投票/归约 → 单一相位判决 | 时序链 |
| 3 | `cdr_loop.m` | 203 | 数字 PI 环路滤波器（Kp/Ki + slew 限幅 + 频率态钳位） | 时序链 |
| 4 | `cdr_pi.m` | 413 | 相位插值器：码累加、UI 回绕、INL/DNL 表 | 时序链 |
| 5 | `cdr_ffe.m` | 151 | 时序路径专用符号间隔 FFE（前馈滤波，主抽头冻结） | 自适应 |
| 6 | `cdr_ffe_loop.m` | 193 | FFE 系数自适应引擎（块级 LMS / SS-LMS + 抽头掩码） | 自适应 |
| 7 | `dlev_loop.m` | 239 | PAM4 判决电平自适应（内/外电平 LMS / SS-LMS） | 自适应 |
| 8 | `loop_monitor.m` | 562 | 因果策略判决器：SNR settle 检测 + 频率态门控 + 静态锁定判据 | 策略 |
| 9 | `cdr_top.m` | 862 | 块级组合根：拥有上述 8 个子块 + 静态 PAM4 slicer + 两级 μ 门控 | 顶层 |

### 1.1 核心结论（**已相对旧版修正，其中 2 条结论方向被反转**）

1. **`cdr_top` 是全部 8 个子块的唯一组合根。** 构造点集中在 `cdr_top.m:265-305`：
   `cdr_pd` / `cdr_voter` / `cdr_loop` / `cdr_pi` / `cdr_ffe` / `cdr_ffe_loop` / `dlev_loop` / `loop_monitor`
   全部在此实例化。8 个子块**互不依赖**（逐文件核对：彼此仅出现在注释中），依赖图是严格星型。
   > ⚠️ 旧版本文档称 "cdr_top 是四模块 BBPD core，ffe / ffe_loop / dlev_loop 未进入 cdr_top 的构造"，
   > 该结论对当前源码**已不成立**，是 2026-09-26 三环整合前的历史状态。

2. **FFE / dLev / FFE-LMS 已完全进入 `cdr_top` 的构造、状态、reset 与块级 Fast 路径**，
   不再是"只能由 validation 脚本手工拼装"。手工拼装路径仍然可用（子块 API 未收窄），
   但已不是唯一路径。

3. **主抽头在四层上一致硬冻结（旧结论反转）。** 当前源码在四处同时保证主抽头不可被改写：

   | 层 | 位置 | 机制 |
   |---|---|---|
   | 构造校验 | `cdr_ffe.m:130-133` | 初始系数主抽头必须 `== 1`，否则 `cdr_ffe:InvalidMainTap` |
   | 增量写入 | `cdr_ffe.m:86-88` | 主抽头位置 delta 非零即抛 `cdr_ffe:MainTapUpdate` |
   | 自适应掩码 | `cdr_ffe_loop.m:146-148` | 掩码使能主抽头即抛 `cdr_ffe_loop:MainTapAdaptEnabled` |
   | 顶层防御 | `cdr_top.m:472-480` | 写入前把主抽头 delta 置零（现为可证死代码，保留作纵深防御） |

   > ⚠️ 旧版本文档称 "主抽头在运行期并未硬冻结，`cdr_ffe` 允许直接改写、`cdr_ffe_loop` 允许自定义掩码使能主抽头"。
   > 该结论对当前源码**已反转**，由 commit `73cd6ef`（四层一致化）与 `6865386` 完成。

4. **`cdr_ffe.scaleCoefficients` 已删除。** 当前 `cdr_ffe` 只有 5 个方法：
   `cdr_ffe` / `processBlock` / `processBlockFast` / `applyCoefficientDelta` / `resetState` / `getState`。
   `cdr_ffe_loop.m:140` 的注释明确记录了该删除。旧文档 §4.4 的 `scaleCoefficients` 行已失效。

5. **`dlev_loop` 的校验边界已上移到构造期，块级数据路径仍是 traced-not-validated。**
   构造期（`dlev_loop.m:68-72`）现在会校验 stepSize / blockSize / 初始电平 / polarity；
   但 `dlevLms` / `dlevSsLms` 对每块传入的 `(d, e)` **不做形状/有限性校验**，
   与 `Fast` 变体的差别只有"是否写 trace"，不是"是否校验"。详见 §6.6。

6. **`loop_monitor` 的对外面已整体更换为 SNR/频率态两检测器**，
   历史的 FFE 写门控（`updateFfeGate` / `enableFfeGate` / `Frozen` / center-touch）**已从源码删除**。
   仍按旧面调用它的 3 个站点现在会直接报错，见 §13.2。

---

## 2. 分层与依赖图

```text
                        ┌──────────────── cdr_top.m:862 ────────────────┐
  ADC code block  ──►   │ processConfiguredBlock (:307)                  │
  (BlockSize×1)         │   └─ 快照 PI 相位 → 入 pending 队列            │
                        │ processPending (:349)  ← 一块流水延迟          │
                        │   1. Ffe.processBlock            (:352)        │
                        │   2. 有效掩码 ValidMask          (:360-379)    │
                        │   3. slicePam4  ← 静态 slicer    (:213-229)    │
                        │   4. Pd.mmpdFast / bbpdFast      (:387-394)    │
                        │   5. Voter.voteFast              (:397)        │
                        │   6. LoopFilter.update           (:405)        │
                        │   7. PhaseInterpolator.update    (:406)        │
                        │   8. Monitor.updateSnrSettle     (:411-421)  ─┐│
                        │   9. Dlev.dlevSsLmsFast          (:423-429)   ││ 两级 μ 门控
                        │  10. Monitor.updateFreqStateGate (:431-456)  ─┘│
                        │  11. FfeLoop.updateSsLmsFast + 写入 (:458-490) │
                        │  12. 组装 38 字段输出            (:492-543)    │
                        └───────────────────────────────────────────────┘
```

**依赖方向**：所有 8 个子块 → 仅被 `cdr_top` 消费；子块之间零依赖。
**归属判据**：`cdr_ffe` 是 *timing-path 专用* FFE，与 data-path 的 `src/RX/@RxFFEDFE`
是两套不同规格（浮点 vs 整数系数、无 DFE vs 带 DFE），见 `docs/ARCHITECTURE.md:37`。

### 2.1 Fast 变体 vs 校验变体：`cdr_top` 的实际选择

`cdr_top` **不是**一律走 Fast。精确划分如下（`cdr_top.m:349-490`）：

| 子块调用 | 变体 | 原因 |
|---|---|---|
| `Ffe.processBlock` (:352) | **校验** | 输入窗口由外部 ADC 码拼接，需校验 |
| `Pd.mmpdFast` / `bbpdFast` (:387-394) | Fast | 判决/误差是 cdr_top 自己刚产生的 |
| `Voter.voteFast` (:397) | Fast | 输入是 PD 刚产生的 |
| `LoopFilter.update` (:405) | **校验** | 标量入口，校验成本可忽略 |
| `PhaseInterpolator.update` (:406) | **校验** | 同上，且需刷新派生状态供 `getLocalIndex` |
| `Dlev.dlevSsLmsFast` (:427) | Fast | 输入是 slicer 刚产生的 |
| `FfeLoop.updateSsLmsFast` (:464) | Fast | 输入是本块刚产生的 |

> ⚠️ `cdr_top.m:400-403` 的注释称"这里及下面几处一律走 Fast 变体"，与上表冲突：
> 环路滤波器与 PI 走的是校验变体。该注释不准确，记录于 §13.1。

---

## 3. 块级时序：一块流水延迟与相位生效延迟

`cdr_top` 不是"喂一块、当场算完"，而是带 **一块 pending 流水**（`cdr_top.m:307-347`）：

```text
caller: code = getSamplingPhase()   ← 用它去采样波形
        out  = processConfiguredBlock(block_k)
                 ├─ 快照当前 PI 状态 (newCode/newSlip)      ← 即 caller 刚用的相位
                 ├─ 若有 pending：processPending(block_{k-1}) ← 本次真正被处理的是上一块
                 │    └─ 该块的 PD/环路/PI 更新在此刻生效
                 └─ 把 block_k 连同快照相位存为新的 pending
```

由此得到两条必须记住的语义：

1. **输出对应的是上一块。** `out.SampleCodeWrapped` / `SampleUiSlip` 是
   *pending 块被采样时*的相位，不是刚喂进来那块的。`out.NextCodeWrapped` / `NextUiSlip`
   才是应用该块 delta 之后的新相位（`cdr_top.m:492-543`）。
2. **相位生效延迟 = 2 块。** block k 的判决在 caller 喂 block k+1 时才更新 PI；
   caller 随后读到的相位用于 block k+2。即闭环延迟为
   *1 块 FFE 窗口死区 + 1 块环路延迟*。
3. **`flush()`** 处理最后一块 pending，其未来样本以零填充，末尾 `PreTapCount` 个
   时隙在 `ValidMask` 中标记为无效。

### 3.1 FFE 窗口与有效掩码

FFE 需要 `PostTapCount` 个过去样本和 `PreTapCount` 个未来样本。跨块边界由 `cdr_top`
负责拼接（`cdr_top.m:352-379`）：输入窗口 = `[上一块尾部 PostTapCount 个][当前块][下一块头部 PreTapCount 个]`。
无法凑齐未来样本的时隙由 `ValidMask` 屏蔽，**不参与** PD、dLev 与 FFE 自适应。

### 3.2 `UnwrappedCode` 的计算口径（**已知耦合假设**）

```matlab
v.UnwrappedCode = uiSlip * cfg.SamplesPerSymbol + codeWrapped;   % cdr_top.m:~500
```

注意这里乘的是 **`SamplesPerSymbol`**，而 `cdr_pi` 自身的累加口径用的是
**`NumCode = 2^PiNumBit`**（`cdr_pi.m:273`）。两者仅在 `2^PiNumBit == SamplesPerSymbol`
时一致（默认 `PiNumBit=7 → 128`，`SamplesPerSymbol=128`，恰好相等）。
`validateConfig` **不强制**这个等式，因此非默认配置下 `UnwrappedCode` 会与 PI 的内部累加
不自洽。记录为潜在缺口，见 §13.3。

---

## 4. `cdr_ffe`：时序路径 FFE

### 4.1 接口

| 方法 | 签名 | 校验 | 说明 |
|---|---|---|---|
| 构造 | `cdr_ffe(initialCoefficients, preTapCount)` | 有 | `cdr_ffe.m:29-45` |
| 滤波 | `processBlock(inputWindow)` | 有 | 校验窗口长度/有限性 |
| 滤波 | `processBlockFast(inputWindow)` | 无 | 数值与 `processBlock` 逐位一致 |
| 写系数 | `applyCoefficientDelta(delta)` | 有 | 主抽头 delta 非零即抛 |
| 复位 | `resetState()` | — | 系数回到构造初值 |
| 读状态 | `getState()` | — | 只读快照 |

### 4.2 抽头几何

默认 `initialCoefficients = [0 0 1 0 0 0]`、`preTapCount = 2`：

```text
索引:      1     2     3      4      5      6
角色:    pre2  pre1  main  post1  post2  post3
初值:      0     0     1      0      0      0
```

- `MainTapIndex = preTapCount + 1 = 3`
- `PostTapCount = TapCount - MainTapIndex = 3`
- 构造期强制 `initialCoefficients(MainTapIndex) == 1`（`cdr_ffe.m:130-133`）

### 4.3 回归向量的时间方向（易错点）

`processBlockFast`（`cdr_ffe.m:54-66`）构造回归矩阵：

```matlab
firstTapSampleIndex = (TapCount-1) + (1:blockLength)';
regressorIndex      = firstTapSampleIndex - (0:TapCount-1);   % 索引递减
```

索引**递减**意味着：系数向量 `[pre2 pre1 main post1 post2 post3]` 依次乘的是
窗口样本 `[未来2 未来1 当前 过去1 过去2 过去3]`。
例：窗口 `1:13`、`TapCount=6`、`blockLength = 13-3-2 = 8`，
第 1 行回归索引为 `[6 5 4 3 2 1]`，第 8 行为 `[13 12 11 10 9 8]`。
**该回归矩阵同时是 `cdr_ffe_loop` 的输入**，两者时间方向必须一致，否则 LMS 会反向收敛。

### 4.4 边界与错误 ID

| 条件 | 错误 ID |
|---|---|
| 输入窗口长度不足 / 含 NaN-Inf | `cdr_ffe:InvalidInputWindow` |
| 初始系数主抽头 ≠ 1 | `cdr_ffe:InvalidMainTap` |
| `preTapCount` 越界 | `cdr_ffe:InvalidPreTapCount` |
| delta 试图改写主抽头 | `cdr_ffe:MainTapUpdate` |

> `scaleCoefficients` **已删除**，不要再引用。

---

## 5. `cdr_ffe_loop`：FFE 自适应引擎

### 5.1 接口

| 方法 | 校验 | 说明 |
|---|---|---|
| `cdr_ffe_loop(stepSize, tapCount, mainTapIndex, adaptEnableMask)` | 有 | `cdr_ffe_loop.m:~25-50` |
| `updateLms(regressors, errors)` | 有 | 标准 LMS，`:63-66` |
| `updateSsLms(regressors, errors)` | 有 | 符号-符号 LMS，`:89-92` |
| `updateLmsFast` / `updateSsLmsFast` | 无 | 仅省去校验与 trace |
| `setStepSize` / `resetState` / `getState` | — | — |

### 5.2 更新律

```matlab
% LMS      (:63-66)
delta = -stepSize * (regressors' * errors) / numel(errors);
% SS-LMS   (:89-92)
delta = -stepSize * (sign(regressors)' * sign(errors)) / numel(errors);
```

两者都**先求块内平均再写入**（块级批更新，不是逐样本）。

### 5.3 抽头掩码与主抽头

- 默认掩码在 `cdr_ffe_loop.m:33-36` 生成：主抽头位置为 `0`，其余为 `1`
  （默认 6 抽头 → `[1 1 0 1 1 1]`）。
- 传入的自定义掩码若使能主抽头，抛 `cdr_ffe_loop:MainTapAdaptEnabled`（`:146-148`）。
- **物理后果**：主抽头恒为 1，均衡只能靠前后抽头整形，游标（cursor）会走位，
  进而造成不同起始相位的锁定相位分叉；分叉离散度 ∝ 捕获期步长。
  这是 ppm 套件把 `FfeStepSize` 默认从 0.004 降到 0.001 的原因（`cdr_top` 库默认仍为 0.004）。

---

## 6. `dlev_loop`：PAM4 判决电平自适应

### 6.1 接口

```matlab
obj = dlev_loop(stepSize, blockSize, levelsInner, levelsOuter, polarity)
%                必填      =64       =1           =3           =1
```

| 方法 | 写 trace | 说明 |
|---|---|---|
| `dlevLmsFast(d, e)` | 否 | 全精度折叠误差 |
| `dlevSsLmsFast(d, e)` | 否 | 符号-符号（RTL bang-bang 对应） |
| `dlevLms(d, e)` | 是 | 与 Fast 数值完全相同 |
| `dlevSsLms(d, e)` | 是 | 同上 |
| `setStepSize` / `resetState` / `getState` | — | `setStepSize` 与构造器同源校验 |

### 6.2 单判决器契约（关键）

输入 `(d, e)` 必须来自 **`cdr_top` 的同一个判决器**：
`d` = 带符号判决电平，`e = x - d` = 判决残差。同一对 `(d, e)` 同时喂给 MMPD 和本环。
这条契约是 `dlev_loop` 归属 CDR 而不是通用 DSP 的根本原因。

### 6.3 折叠误差与归属（`dlev_loop.m:163-175`）

```matlab
isInner   = abs(d) == obj.DLevInner;
isOuter   = abs(d) == obj.DLevOuter;
foldedErr = sign(d) .* e;          % 恒等于 |x| - |d|
innerErr  = foldedErr .* isInner;  % 环外样本置零
outerErr  = foldedErr .* isOuter;
```

`innerErr` 与 `outerErr` **互补**，逐样本至多一个非零。
归属用 `==` 精确比较：`d` 只会取 `±DLevInner / ±DLevOuter` 四个值之一，故成立。

### 6.4 块更新（`dlev_loop.m:177-193`）

```matlab
gradInner = sum(innerTerm) / obj.BlockSize;   % 注意：除的是 BlockSize，不是本环样本数
gradOuter = sum(outerTerm) / obj.BlockSize;
DLevInner += StepSize * Polarity * gradInner;
DLevOuter += StepSize * Polarity * gradOuter;
Threshold  = (DLevInner + DLevOuter) / 2;
```

**除数是 `BlockSize` 而非各环实际命中样本数。** PAM4 下内外环各占约一半，
因此两环的有效增益约为名义 `StepSize` 的一半，且随码型统计波动。
这是设计选择（对应 RTL 的定长累加器），不是缺陷，但调参时必须知道。

SS-LMS 变体把 `innerTerm` 换成 `sign(innerErr)`：由于环外样本已置零，
`sign(0) = 0`，环外样本自然不贡献。

### 6.5 门限

`Threshold` 是**内外电平的算术中点**，每次更新后重算。`cdr_top` 的静态 slicer
用它区分 inner/outer（`cdr_top.m:213-229`）。

### 6.6 校验边界（**相对旧版已变化**）

| 环节 | 是否校验 | 位置 |
|---|---|---|
| 构造期 stepSize / blockSize / 两电平 / polarity | **是** | `dlev_loop.m:68-72` |
| `setStepSize` | **是**（与构造同源） | `:157` |
| 块级 `(d, e)` 形状 / 有限性 | **否** | `dlevLms` / `dlevSsLms` 均不校验 |
| `DLevInner < DLevOuter` 是否保持 | **否** | 无任何单调性维护 |
| 电平是否保持为正 | **否** | 步长过大可穿越零点 |

因此：`dlevLms` 与 `dlevLmsFast` 的差别 **只有 trace**，不是"校验版 vs 快速版"。
对外文档不得把 `dlevLms` 描述为 validated API。

错误 ID：`dlev_loop:MissingStepSize` / `InvalidStepSize` / `InvalidBlockSize` /
`InvalidLevelsInner` / `InvalidLevelsOuter` / `InvalidPolarity`。

---

## 7. `cdr_pd`：相位检测器

### 7.1 接口

```matlab
obj = cdr_pd(mode, polarity)        % mode: 'nrz' | 'pam4'，polarity: ±1
[pd, valid, out] = bbpd (dataPrev, edgeBit, dataCurr)                              % 校验
[pd, valid]      = bbpdFast(dataPrev, edgeBit, dataCurr)                           % 无校验
[pd, valid, out] = mmpd (dataPrev, errorPrev, dataCurr, errorCurr, transitionFilter) % 校验
[pd, valid]      = mmpdFast(...)                                                    % 无校验
```

`mmpd` 仅支持 PAM4（`ModeId ~= 1` 抛 `cdr_pd:MMPDUnsupportedMode`，`:112-115`）。

### 7.2 MMPD 判决律（`cdr_pd.m:147-168`）

```matlab
sameError        = errorPrev == errorCurr;      % 两侧误差位一致才计入
errorHigh        = errorPrev ~= 0;
risingTransition = dataCurr > dataPrev;
valid            = sameError & dataTransition;
early            = valid & ((~rising & errorHigh) | (rising & ~errorHigh));
phaseDecision(valid) = -polarity;   % 默认 late
phaseDecision(early) = +polarity;   % 覆盖为 early
```

即：**下降跳变时 error=1 为 early、0 为 late；上升跳变时符号相反。**
所有有效跳变权重相同，**没有**对称跳变 2× 加权。

### 7.3 `transitionFilter`：三模式枚举（**旧版只记录了两模式**）

`cdr_pd.m:153-160`：

| 值 | 参与判决的跳变 | 每块事件数（PAM4 均匀码型，BlockSize=64） |
|---|---|---|
| `0` / `false` | 全部非静止跳变 `dataPrev ~= dataCurr` | ~48 |
| `1` / `true` | 对称跳变 `0<->3` 与 `1<->2` | ~16 |
| `2` | 仅外层 `0<->3` | ~8 |

校验在 `:104-110`：接受 scalar logical 或数值 `0/1/2`，否则抛
`cdr_pd:InvalidTransitionFilter`。

**实测取舍（开环偏置 vs 闭环增益）**，−100 ppm / phase 0：

| 模式 | 开环 PD 偏置 `[101:300]` 均值 | −50 ppm 闭环全相位锁定 |
|---|---|---|
| 0 | −0.02312 | — |
| 1 | −0.01586 | **4/8** |
| 2 | −0.00023（偏置降 69×） | 0/8 |

模式 2 偏置最小却闭环最差：事件数减半后环路增益追不上漂移的眼。
**结论：`1` 是甜点，也是 `cdr_top` 的默认值。** 过滤只能在偏置与增益之间搬运，
不能创造眼张开度。

### 7.4 BBPD

`bbpd(dataPrev, edgeBit, dataCurr)` 用边沿采样位判 early/late，
仅在 `dataPrev ~= dataCurr` 时有效。保留供 NRZ 与历史回放使用，
`cdr_top` 默认检测器已是 MMPD。

### 7.5 错误 ID

`cdr_pd:InvalidMode` / `InvalidModeId` / `InvalidPolarity` / `SizeMismatch` /
`InvalidDigitalInput` / `InvalidTransitionFilter` / `MMPDUnsupportedMode`。

---

## 8. `cdr_voter`：块内归约

### 8.1 接口（**第 4 个参数与 `mean` 模式为旧版缺失内容**）

```matlab
obj = cdr_voter(mode, blockSize, constantMagnitude, meanDenominator)
%               'linear'  =64      =8                 ='auto'
phaseError = vote(phaseDecision);      % 校验：必须只含 -1/0/+1
phaseError = voteFast(phaseDecision);  % 无校验
```

### 8.2 三种模式（`cdr_voter.m:57-83`）

| `mode` | `ModeId` | 输出 | 类型 |
|---|---|---|---|
| `'linear'` | 0 | `sum(int16(phaseDecision))`，原生 int16 饱和累加 | `int16` |
| `'constant'` | 1 | `sign(sum) * ConstantMagnitude` | `int16` |
| `'mean'` | 2 | `sum(double(pd)) / denominator` | `double` |

`'mean'` 的分母：`MeanDenominator == 'auto'` 时取 `numel(phaseDecision)`
（即本块实际长度），否则取配置的固定分母。
**固定分母才对应 RTL 的定标右移**；`'auto'` 会随块长变化改变环路增益。

### 8.3 类型契约

`linear` / `constant` 返回 **`int16`**，`mean` 返回 **`double`**。
下游 `cdr_loop` 接收后按 double 运算，但切换 voter 模式会改变环路增益量纲，
不能只改 `VoterMode` 而不重新标定 `Kp/Ki`。

错误 ID：`cdr_voter:InvalidMode` / `InvalidPhaseDecision` / `InvalidConfiguration`。

---

## 9. `cdr_loop`：PI 环路滤波器

### 9.1 接口

```matlab
obj = cdr_loop(Kp, Ki, frequencyMin, frequencyMax, maxDeltaCode)
deltaCode = update(phaseError);      % 校验（cdr_top 用这个）
deltaCode = updateFast(phaseError);  % 无校验
setGains / setFrequencyLimits / setMaxDeltaCode / resetState / getState
```

### 9.2 更新律（`cdr_loop.m:~70-99`）

```matlab
frequencyState = clamp(FrequencyState + Ki*phaseError, FrequencyMin, FrequencyMax);
control        = Kp*phaseError + frequencyState;
residueAccum   = CodeResidue + control;
rawDeltaCode   = fix(residueAccum);                        % 向零取整
pendingAccum   = PendingCode + rawDeltaCode;
deltaCode      = clamp(pendingAccum, -MaxDeltaCode, MaxDeltaCode);  % slew 限幅

CodeResidue = residueAccum - rawDeltaCode;   % 只留不足 1 code 的小数
PendingCode = pendingAccum - deltaCode;      % 被 slew 限幅吞掉的整数 code
```

**三个状态量的分工必须分清：**

| 状态 | 单位 | 含义 |
|---|---|---|
| `FrequencyState` | code/block | 积分器 = 频差估计。ppm 场景下其尾窗均值就是锁定判据的主量 |
| `CodeResidue` | code（\|·\|<1） | 小数残量，防止小于 1 code 的控制量被丢弃 |
| `PendingCode` | code（整数） | **被 slew 限幅拒绝执行的积压**。是 slew 饱和的极灵敏先兆 |

### 9.3 slew 饱和的判别特征

实测（`MaxDeltaCode = 1`）：

| ppm | slew 利用率 | `mean\|PendingCode\|` |
|---|---|---|
| +100 | 0.819 | 0.13 |
| +110 | 0.901 | 0.44 |
| +120 | 0.983 | 7~9 |
| +130 | 1.065 | 5408~7883（`DeltaCode` 均值精确 1.000，钳死） |

`PendingCode` 在越限前就开始发散，比 `DeltaCode` 早得多。
`loop_monitor` 的饱和守卫据此设计（§11.4）。

### 9.4 边界

- `MaxDeltaCode` 必须是 **正整数或 `Inf`**（`cdr_loop.m:128-140`），否则
  `cdr_loop:InvalidMaxDeltaCode`。`Inf` = 不限 slew。
- `Kp`/`Ki` 必须非负有限；`frequencyMin <= frequencyMax`，否则
  `cdr_loop:InvalidFrequencyLimits`。
- `setFrequencyLimits` 会**立即把当前 `FrequencyState` 夹回新区间**。
- `resetState` 清零动态状态但保留增益与限幅配置。
- 本模块**不感知 voter 模式，也不负责 PI code 回绕**。

---

## 10. `cdr_pi`：相位插值器

### 10.1 接口

```matlab
obj = cdr_pi(NumBit, SamplesPerSymbol)     % NumCode = 2^NumBit
update(deltaCode)                  % 校验 + refreshOutputState（cdr_top 用这个）
localIndexFloat = updateFast(deltaCode)    % 无校验、不刷新派生状态
setCode / resetState / resetNonideal / setDefaultNonideal
setInlTableUI / setPhaseTableUI
getPhaseUI / getIndex / getLocalIndex / getInlTableUI / getState
```

### 10.2 码累加与 UI 回绕（`cdr_pi.m:102-146`）

```matlab
rawCode    = CodeWrapped + deltaCode;
uiDelta    = floor(rawCode / NumCode);
CodeWrapped = mod(rawCode, NumCode);
UiSlip      = UiSlip + uiDelta;
```

`getState().CodeAccum = UiSlip * NumCode + CodeWrapped`（`cdr_pi.m:273`）。
⚠️ 注意 `cdr_top` 的 `UnwrappedCode` 用的是 `SamplesPerSymbol` 而不是 `NumCode`，
见 §3.2。

### 10.3 `update` vs `updateFast` 的关键差别

`updateFast` **不调用 `refreshOutputState`**，因此调用后
`PhaseWrappedUI` / `PhaseAccumUI` / `Index*` / `LocalIndexFloat` 可能是陈旧值。
`cdr_top` 在 `:406` 走的是 **`update`**，正是为了让随后的 `getLocalIndex()`
（`cdr_top.m:496`）拿到新鲜值。**不要把这里"优化"成 `updateFast`。**

### 10.4 非理想性

- `setInlTableUI(inlTableUI)`：逐码 INL（单位 UI），长度必须 `== NumCode`。
- `setPhaseTableUI(phaseTableUI)`：直接给出完整相位表，绕过理想 + INL 合成。
- `buildAbConstantPhaseTableUI`（`:317-370`）：A/B 常数插值器模型，
  用于生成带结构性 DNL 的相位表。
- `resetNonideal` 回到理想线性表；`setDefaultNonideal` 装载默认非理想表。

---

## 11. `loop_monitor`：因果策略判决器（**旧版文档完全缺失本节**）

### 11.1 定位

`loop_monitor` 不在信号路径上，**不产生任何信号**。它只观察标量流并输出布尔判决，
供 `cdr_top` 做 μ 换挡。契约有三条：

1. **因果**：只用当前及历史样本，绝不回看未来。
2. **有界内存**：EWMA 单标量 + 定长环形缓冲，不随仿真长度增长。
3. **只判决不执行**：自身不修改任何环路参数，换挡动作由 `cdr_top` 执行。

### 11.2 接口（**构造函数现为零参**）

```matlab
obj = loop_monitor()                                   % :62，无参数
enableSnrSettle(thresholdDb, alpha, minBlock)          % :81
triggered = updateSnrSettle(blockIndex, snrDb)         % :119
enableFreqStateGate(windowBlocks, expectedRate, ...)   % :160
[triggered, diag] = updateFreqStateGate(blockIndex, freqState)  % :215
state = getState();  resetState();
% 静态离线判据：
[locked, diag] = loop_monitor.detectFrequencyStateLock(freqStateSeq, ...)  % :317
[locked, diag] = loop_monitor.detectRotationPeriodLock(unwrappedSeq, ...)  % :367
```

> ⚠️ 历史的 FFE 写门控面 —— `enableFfeGate` / `updateFfeGate` / `Frozen` 属性 /
> center-touch 冻结判据 —— **已从源码整体删除**。仍按旧面调用的 3 个站点见 §13.2。

### 11.3 SNR settle 检测器（stage-1 门）

```matlab
ewmaDb = alpha*snrDb + (1-alpha)*ewmaDb;     % 首个可用值播种
done   = (block >= minBlock) && (ewmaDb >= thresholdDb);
```

- 非有限读数**跳过**（不污染 EWMA），不计入。
- `done` 一旦为真即**锁存**，不会回落。

**为什么必须是 EWMA 而不是逐块阈值**：逐块 SNR 分布严重重叠 ——
失败运行的 p99 = 22.55 dB，反而高于成功运行尾段的最小值 17.50 dB
（钳位后 PI 旋转会扫过眼心，瞬时 SNR 很高但环路是错的）。
`α = 1/128` 时失败峰值 13.02~13.12 dB vs 眼开 21.6~24.4 dB，可分。
阈值 11 dB 会打断 −100 ppm，`>= 12` 可行，**默认取 15 dB**。

### 11.4 频率态门控（stage-2 门）+ slew 饱和守卫

尾窗判据：频率态均值恒定（分半差 + std + 与理论值
`-ppm*1e-6*128*64` code/block 的量级匹配）。

饱和否决项：
```
mean|DeltaCode| >= SlewSatDeltaFrac(0.98) * MaxDeltaCode   或
mean|PendingCode| >= SlewSatPendingTol(0.5)
```
→ 判饱和，**否决锁定**。同时 `slewUtilization = |expectedFreqState| / MaxDeltaCode`，
`>= 1` 抛 warning `cdr_three_loop_ppm:SlewLimitExceeded`。

### 11.5 旋转周期判据只能当佐证

`detectRotationPeriodLock` 检查 UI-slip 间隔的 CoV。**它会被 slew 饱和骗过**：
+130 ppm 饱和时旋转周期精确为 128.0 block（1 code/block 走满 128 码），
绝对容差 16 下 `|128 − 120.2| = 7.8` 会误判通过。
修复：容差改相对 `RotPeriodTolFrac = 0.03`，`tol = max(2, frac*expectedPeriod)`
→ 3.61，正确拒绝。

**适用性门**：小 ppm 下旋转周期超过尾窗，判据不适用。
`rotationApplicable = window/period >= RotMinIntervals + 1`，
不适用时只用频率态判据并报 `RotationCriterionApplicable = false`。
（此前 −10 ppm 误报 0/8 就是缺这个门。）

**定论：频率态为主判据，旋转周期仅为佐证。**

---

## 12. `cdr_top`：组合根

### 12.1 构造

只接受**一个完整配置结构体**。`cdr_top.defaultConfig()`（`:142-211`）返回可直接构造的默认配置。

| 组 | 字段 = 默认值 |
|---|---|
| 块几何 | `BlockSize=64`, `SamplesPerSymbol=128` |
| PD | `Detector='mmpd'`, `TransitionFilter=true`(即 1), `PdPolarity=1` |
| Voter | `VoterMode='mean'`, `VoterDenominator='auto'` |
| 环路 | `Kp=8`, `Ki=0.03`, `FrequencyLimit=4`, `MaxDeltaCode=1` |
| PI | `PiNumBit=7`, `PiNonideal='ab_constant'`, `PiInitialCode=0` |
| dLev | `DlevInnerInit=16`, `DlevOuterInit=48`, `DlevPolarity=1` |
| dLev μ 三档 | `0.5`(捕获) → `0.1`(settle) → `0.02`(PVT) |
| Stage-1 门 | `SnrSettleThresholdDb=15`, `SnrSettleAlpha=1/128`, `SnrSettleMinBlock=200` |
| FFE | `FfeInitCoefficients=[0 0 1 0 0 0]`, `FfePreTapCount=2`, `FfeAdaptEnableMask=[1 1 0 1 1 1]` |
| FFE μ 三档 | `0.004`(捕获) → `2e-4`(settle) → `2e-4`(PVT) |
| Stage-2 门 | `FfeGateEnable=true`, `FfeGateMode='pvt-track'`, `FfeGateCriterion='freq-state'` |
| freq 门参数 | `WindowBlocks=2000`, `MeanHalfDiffTol=1e-3`, `StdTol=5e-3`, `RateTol=Inf`, `SatFrac=0.9` |

### 12.2 静态 PAM4 slicer（`cdr_top.m:213-229`）

```matlab
isOuter   = abs(sample) >= threshold;
magnitude = dLevInner + (dLevOuter - dLevInner) .* isOuter;
decision  = ±magnitude;              % 符号取自 sample
sliceError = sample - decision;
dataSymbol = isPositive*2 + (isPositive == isOuter);   % 0=-3, 1=-1, 2=+1, 3=+3
errorBit   = double(sliceError >= 0);
```

`dataSymbol` 是**自然序**映射（非 Gray）。这一个判决器同时供 MMPD、dLev 环、
FFE 误差与 SNR FOM 使用 —— 即 §6.2 的单判决器契约。

### 12.3 眼质量 FOM（`cdr_top.m:230-248`）

```matlab
snrDb = 10*log10(mean(decision.^2) / mean(sliceError.^2));
```
空块 → `NaN`；误差功率为 0 → `Inf`。
**判决导向而非真值参考**：闭眼判错时误差是相对"错误的"电平算的，
单块读数可能偏乐观，因此只能配合 EWMA 使用（§11.3）。

### 12.4 两级 μ 门控（`cdr_top.m:405-456`）

```text
捕获档  dLev 0.5   / FFE 0.004
   │ stage-1: SNR EWMA >= 15 dB 且 block >= 200
   ▼
settle档 dLev 0.1  / FFE 2e-4
   │ stage-2: 频率态尾窗平坦（且未 railed）
   ▼
PVT档   dLev 0.02 / FFE 2e-4
```

**调度顺序有一个显式防倒挂保护**（`:412-421`）：stage-1 在本函数中先执行，
若 stage-2 曾在更早的块闩锁，再施加 settle 档会把已降到 PVT 的步长**抬回去**
（0.02 → 0.1）。因此 stage-1 只在 `~gateLatched()` 时才生效。改这段务必保留该条件。

**stage-1 门的历史教训**：2026-09-26 前用的是 dLev 外电平位移门
`abs(outer - outer_{k-W}) <= tol`，等价于隐式速率门限 `tol/W = 0.5/16 = 0.031 code/block`。
冷启动 dLev 实际漂移率只有 0.012，于是 block 84 就误判 settle
（此时 outer=41.36，终值 31.99，还剩 59% 行程）→ FFE 步长被砍 20× → 眼开不了 →
PD 偏置持续为负 → 积分绕到 −4 钳位 → −100 ppm 0/32。
隔离实验：只保 FFE 捕获步长 8/8，只保 dLev 步长 0/8 ⇒ **致命的是 FFE 的 20×**。

### 12.5 输出：38 个字段

`cdr_top.m:492-543` 把 38 个值填进局部结构体 `v`（顺序随意），再交给
**`buildConfiguredOutput`** 统一装配。字段名与顺序的**单一真相源**在该方法里，
空块路径 `emptyConfiguredOutput` 走同一个装配器，两种输出不会漂移。
新增字段必须同时改这两处。

| 组 | 字段 |
|---|---|
| 块标识 | `HasOutput`, `BlockIndex`, `ValidMask` |
| 采样相位（**对应 pending 块**） | `SampleCodeWrapped`, `SampleUiSlip`, `UnwrappedCode` |
| 信号 | `FfeOutput`, `Decision`, `SliceError`, `DataSymbol`, `ErrorBit` |
| PD/环路 | `PhaseDecision`, `ValidTransition`, `PhaseError`, `DeltaCode`, `LoopControl`, `LoopFrequencyState`, `LoopCodeResidue`, `LoopPendingCode` |
| 下一相位 | `NextCodeWrapped`, `NextUiSlip` |
| dLev | `DlevInner`, `DlevOuter`, `DlevThreshold`, `DlevStepSize` |
| FFE | `FfeCoefficients`, `FfeRawDelta`, `FfeAppliedDelta`, `FfeProposedCoefficients`, `FfeAdaptationCalculated`, `FfeWriteApplied`, `FfeStepSize` |
| 策略 | `LoopLockedEvent`, `GateEngaged`, `SnrDb`, `SnrEwmaDb`, `SnrSettleDone`, `SnrSettleBlock` |

### 12.6 `result.PdOffset` 是死配置

v3/v4 runner 仍把 `result.PdOffset = -0.05` 写进结果 MAT
（v3:228/1143/1434、v4:690/882），但 `cdr_top` 不读该字段。
**这是误导性元数据，不是生效参数。**

---

## 13. 已知缺口与源码内部不一致

> 本节只记录事实，不做修正。每条都以当前源码为准。

### 13.1 源码注释与源码本身冲突

| 位置 | 注释声称 | 源码实际 |
|---|---|---|
| `cdr_top.m:400-403` | "这里及下面几处一律走 Fast 变体" | `LoopFilter.update` / `PhaseInterpolator.update` 是**校验**变体 |
| `cdr_top.m:184-188` | "loop_monitor 的构造器仍要求它们，所以构造处传入固定的惰性常量" | `loop_monitor()` 是**零参**构造；`cdr_top.m:283` 也确实没传参 |
| `cdr_top.m:193-194` | "loop_monitor 仍保留 `updateFfeGate` 供旧 MAT 的离线回放" | `loop_monitor` 中**已无** `updateFfeGate` |
| `loop_monitor.m:88-89, 177-178` | "让文档所述的 4 参数构造函数对每个既有调用方都保持有效" | 构造函数是零参，4 参数调用方会直接报错 |
| `cdr_pd.m:98-99, 142-143` | `transitionFilter` 是 `false/true` 二值 | 实际接受 `0/1/2` 三值（`:104-110`） |

### 13.2 按已删除接口调用 `loop_monitor` 的 3 个站点（**当前会报错**）

| 站点 | 调用形式 |
|---|---|
| `tests/CDR/test_freq_state_gate.m:31` | `loop_monitor(500, 100, 3, 1)` → `MATLAB:TooManyInputs` |
| `validation/.../make_ppm_stage_eyes.m:498, 504` | 4 参构造 + `monitor.updateFfeGate(...)` |
| `validation/.../write_ppm_lock_summary_txt.m:444, 450` | 同上 |

后两个是旧 MAT 的离线回放工具，当前**无法运行**。

### 13.3 `UnwrappedCode` 的量纲耦合

`cdr_top` 用 `SamplesPerSymbol`、`cdr_pi` 用 `NumCode = 2^PiNumBit`。
仅在二者相等时自洽（默认 128 == 128），`validateConfig` **不强制**该等式。见 §3.2。

### 13.4 已证否的方案（不要重试）

- 任何 `(W, tol)` 组合或固定块触发的 dLev 位移门 —— 无法让 −100/+100/0 ppm 三者同时通过。
- outer-only 跳变过滤（`transitionFilter=2`）—— 偏置降 69× 但事件数减半，闭环更差。
- `FreqAcqPonly`（捕获期只用 P 支路）—— 旧门控在 block 84 就放开了 Ki，无效。
- 闭眼期用 PD 端信息筛选解决捕获 —— 过滤只能在偏置与增益间搬运，**不能创造眼张开度**。
  出路只有预置系数（planA）或盲均衡（CMA）注入信息。

---

## 14. 当前测试证据（2026-09-30 实跑，MATLAB R2025b）

| 套件 | 结果 |
|---|---|
| `test_cdr_ffe` | **PASS 7/7** |
| `test_cdr_ffe_loop` | **PASS 8/8** |
| `test_cdr_loop` | **PASS 10/10** |
| `test_cdr_voter` | **PASS 7/7** |
| `test_loop_monitor` | **PASS 4/4** |
| `test_cdr_top_configured` | **PASS 12/12** |
| `test_cdr_pd` | **12/13**，1 项失败 |
| `test_freq_state_gate` | **FAIL**（构造函数 arity） |

**两项失败都是"测试停留在旧契约"，不是源码回归：**

1. `test_cdr_pd`："MMPD transition-filter validation: invalid transition filter case 1 should throw"
   —— 测试仍假设该值非法，但源码现在接受 `0/1/2`。
2. `test_freq_state_gate` —— 见 §13.2，按 4 参构造零参构造函数。

> 对比：旧文档记录的 `test_cdr_ffe` / `test_cdr_ffe_loop` 失败（主抽头保护缺失）
> **已由 commit `73cd6ef` 修复**，现在两套件全绿。

---

## 15. 一页速查

- **9 个 class，星型依赖，唯一组合根是 `cdr_top`。** 子块之间零依赖。
- **主抽头四层硬冻结**，恒为 1，不可适配（这是锁定相位分叉的物理来源）。
- **一块流水延迟**：输出对应 pending 块；相位生效延迟 2 块。
- **单判决器契约**：一个 slicer 同时喂 MMPD / dLev / FFE 误差 / SNR FOM。
- **Fast ≠ 无校验**：`dlev_loop` 的 Fast 与普通版只差 trace；`cdr_top` 对
  环路滤波器与 PI 刻意用**校验**变体。
- **两级 μ 门控**：SNR EWMA (15 dB) → 频率态平坦；stage-1 有防倒挂条件，勿删。
- **`transitionFilter` 是 0/1/2 三值**，`1`（对称跳变）是甜点。
- **`PendingCode` 是 slew 饱和的先兆**，比 `DeltaCode` 早发散。
- **频率态是主判据，旋转周期只是佐证**（后者会被 slew 饱和骗过）。
- 改动本目录任何契约后，请同步刷新本文件的 §13 与 §14。
