# CDR Sub Block 实现与核心逻辑

> 审阅范围：`C:\Work\MatLab_Lib\src\CDR` 下当前 8 个 MATLAB class。
>
> 审阅日期：2026-09-22  
> 当前分支：`codex/mmpd-weighted-transitions-v1`  
> `src/CDR` 最近提交：`38527cd897a994527ada1789da6306c4f3634dd8`  
> 文档原则：以当前源码行为为准；历史 validation 结果仅作为带边界的证据，不替代源码契约。

---

## 1. 文档目的与结论

`src/CDR` 目前包含 8 个 sub block：

| Sub block | 文件 | 主要职责 |
|---|---|---|
| CDR FFE | `src/CDR/cdr_ffe.m` | 符号速率浮点 FIR；由调用方提供包含过去/当前/未来样本的完整窗口 |
| CDR FFE adaptation | `src/CDR/cdr_ffe_loop.m` | 按 block 计算标准 LMS 或 Sign-Sign LMS 系数增量 |
| dLev adaptation | `src/CDR/dlev_loop.m` | 跟踪 PAM4 内、外两组对称判决电平，并维护判决门限 |
| Phase detector | `src/CDR/cdr_pd.m` | 数字 NRZ/PAM4 BBPD，以及 PAM4 二值误差 MMPD |
| Voter | `src/CDR/cdr_voter.m` | 将一个并行 block 的 `-1/0/+1` 相位判决压缩为一个 phase error |
| Loop filter | `src/CDR/cdr_loop.m` | 浮点 PI 环路滤波、整数 PI code 量化、slew limit 和 backlog |
| Phase interpolator | `src/CDR/cdr_pi.m` | PI code 累加/wrap、UI slip、非理想 LUT 和采样索引映射 |
| Digital top | `src/CDR/cdr_top.m` | 组合 `BBPD → voter → loop → PI`，管理 block 时序和 previous-symbol 状态 |

核心结论：

1. 当前 `cdr_top` 是一个**四模块数字 BBPD CDR core**，不是 8 个模块的统一 waveform-level CDR 顶层。它只组合 `cdr_pd.bbpd`、`cdr_voter`、`cdr_loop` 和 `cdr_pi`（`src/CDR/cdr_top.m:64-86,101-110`）。
2. `cdr_ffe`、`cdr_ffe_loop`、`dlev_loop` 以及 `cdr_pd.mmpd` 已分别实现，但仍由 validation runner 或更外层调用方手工编排；它们没有进入 `cdr_top` 的构造、状态、复位或 Fast API（`src/CDR/cdr_top.m:19-25,177-214`）。
3. 当前控制时序是：**block k 使用旧采样相位，block k 的判决在块末更新 PI，新相位从 block k+1 生效**（`src/CDR/cdr_top.m:97-116`）。
4. 多数模块提供 validated/debug 路径和 reduced-overhead Fast 路径；但 `dlev_loop` 的普通接口只是“带轨迹版本”，并没有完整输入校验，不能按其他类的惯例理解成 validated API（`src/CDR/dlev_loop.m:73-104,151-180`）。
5. 当前源码的“主抽头固定”是**默认适配掩码的行为，不是所有底层接口共同强制的不变量**：`cdr_ffe` 可直接修改或缩放主抽头，`cdr_ffe_loop` 也允许调用方用自定义 mask 开启主抽头适配（`src/CDR/cdr_ffe.m:55-68,86-94`; `src/CDR/cdr_ffe_loop.m:33-36,130-140`）。

---

## 2. 总体架构与数据流

### 2.1 当前 `cdr_top` 已实现的数字闭环

```text
上游已经完成的 data/edge 数字判决
                    │
                    ▼
       cdr_pd.bbpd / bbpdFast
       每 UI 输出 phaseDecision ∈ {-1,0,+1}
                    │
                    ▼
          cdr_voter.vote
       每 block 输出一个 phaseError
                    │
                    ▼
          cdr_loop.update
       每 block 输出整数值 deltaCode
                    │
                    ▼
           cdr_pi.update
  wrap PI code、累计 UiSlip、查 LUT 得到下一 block 相位
```

`cdr_top` 对这条链的职责是：

- 保存上一 block 的最后一个 data symbol；
- 为当前 block 构造与 `D[n]` 对齐的 `D[n-1]`；
- 固定 PD、voter、loop filter、PI 的调用顺序；
- 区分当前 block 使用的相位和下一 block 使用的相位；
- 同步复位 PD、loop、PI 和顶层调度状态；
- 提供 debug 路径和 Fast 路径（`src/CDR/cdr_top.m:4-25,89-175`）。

### 2.2 当前仍在 `cdr_top` 外部的 waveform/adaptation 路径

```text
模拟/缓存 waveform
      │
      ▼
 sampler / TI ADC                    （当前在 cdr_top 外）
      │ chronological code samples
      ▼
 cdr_ffe                             （当前在 cdr_top 外）
      │ output + regressor
      ▼
 unified PAM4 slicer                 （当前在 cdr_top 外）
      ├──────── data symbol / edge bit / error bit ───────┐
      │                                                    │
      ├─> cdr_pd BBPD/MMPD ─> voter ─> loop ─> PI          │
      ├─> dlev_loop：更新内/外判决电平和门限               │
      └─> cdr_ffe_loop：计算系数 delta ─> cdr_ffe          │
```

因此需要明确区分：

- **组件已实现**：类和核心算法已经存在；
- **当前数字顶层已集成**：只有 BBPD、voter、loop、PI；
- **validation runner 已手工组合**：不等于 `cdr_top` 已拥有该接口、状态和复位语义。

---

## 3. Block 级时序

设第 `k` 个 block 开始时：

- 当前本地采样偏移为 `phi[k]`；
- 上一 block 最后一个 symbol 为 `P[k]`；
- 当前数字 data block 为 `D[k]`；
- 当前 edge-bit block 为 `E[k]`。

当前 `cdr_top` 的一次 transaction 如下：

| 顺序 | 动作 | 本 block / 下一 block 语义 |
|---:|---|---|
| 1 | 外部 sampler 按 `phi[k]` 采样并完成 slicer | 发生在调用 `cdr_top` 之前 |
| 2 | 构造 `Dprev = [P[k], D[k](1:end-1)]` | 给当前 block 的 PD 使用 |
| 3 | `cdr_pd.bbpd(Dprev,E[k],D[k])` | 每 UI 产生 `-1/0/+1` |
| 4 | `cdr_voter.vote(phaseDecision)` | 当前 block 聚合成一个 phase error |
| 5 | `cdr_loop.update(phaseError)` | 更新 PI/filter 状态并产生 `deltaCode[k]` |
| 6 | `cdr_pi.update(deltaCode[k])` | 生成 `phi[k+1]` |
| 7 | 保存 `P[k+1] = D[k](end)` | 下一 block 的 boundary overlap |
| 8 | `BlockIndex += 1` | 当前 transaction 完成 |

跨 block 历史的精确实现为：

```matlab
Dprev(1)     = PreviousSymbol;
Dprev(2:end) = Dcurr(1:end-1);
```

并显式保持行/列方向一致（`src/CDR/cdr_top.m:218-231`）。

注意：`cdr_top` 自身并不从 waveform 采样。所谓“当前 block 使用旧相位”依赖上层先读取 `CurrentLocalIndexFloat`、完成采样和 slicing，再调用 `processBlock`。顶层输出中的：

- `SampleIndexForBlock`：当前 block 已经使用的更新前相位；
- `NextLocalIndexFloat`：PI 更新后、供下一 block 使用的相位；

二者不能混用（`src/CDR/cdr_top.m:97-116,117-139`）。

---

## 4. `cdr_ffe`：符号速率 CDR FFE

### 4.1 职责与状态

`cdr_ffe` 是一个无跨 block 输入缓存的浮点 FIR。它只负责：

- 保存初始系数和当前系数；
- 根据完整输入窗口计算目标 block 的输出；
- 同时生成 LMS 所需的 regressor；
- 接受外部计算出的系数增量；
- reset 时恢复初始系数。

它**不负责**：

- past/future 样本缓存；
- look-ahead 调度；
- block 首尾有效性；
- slicer、误差构造或 LMS；
- 系数量化、乘法器位宽、截断、饱和或 DFE。

输入窗口固定为：

```text
[PostTapCount 个过去样本, 目标 block, PreTapCount 个未来样本]
```

这些边界在类头部直接声明（`src/CDR/cdr_ffe.m:2-8`）。

### 4.2 默认配置

构造接口：

```matlab
ffe = cdr_ffe(initialCoefficients, preTapCount)
```

默认：

```matlab
initialCoefficients = [0 0 1 0 0 0];
preTapCount = 2;
```

由此：

- `TapCount = 6`；
- `MainTapIndex = 3`；
- `PostTapCount = 3`；
- 抽头语义为 `[pre2, pre1, main, post1, post2, post3]`。

见 `src/CDR/cdr_ffe.m:20-35`。

构造阶段要求 `initialCoefficients(MainTapIndex) == 1`（`src/CDR/cdr_ffe.m:98-121`）。这是**初始值约束**，不是运行期硬冻结。

### 4.3 FIR / regressor 核心逻辑

设：

- 输入窗口长度为 `L`；
- tap 数为 `T`；
- precursor 数为 `P`；
- postcursor 数为 `Q = T-P-1`；
- 目标 block 长度为 `N = L-P-Q`。

源码构造：

```matlab
firstTapSampleIndex = (T - 1) + (1:N).';
tapOffset = 0:T-1;
regressorIndex = firstTapSampleIndex - tapOffset;
X = inputWindow(regressorIndex);
y = (X * coefficients.').';
```

见 `src/CDR/cdr_ffe.m:45-53`。

矩阵公式为：

```text
y = X * c
```

默认六抽头时，每一行 regressor 的顺序是：

```text
[future2, future1, current, past1, past2, past3]
```

因此它与系数语义 `[pre2,pre1,main,post1,post2,post3]` 一一对应。测试用 `inputWindow=1:13` 验证首行 `[6 5 4 3 2 1]`、末行 `[13 12 11 10 9 8]`（`tests/CDR/test_cdr_ffe.m:20-30`）。

### 4.4 API

| API | 行为 |
|---|---|
| `processBlock` | 检查有限实数行向量、转为 double，再调用 Fast 内核 |
| `processBlockFast` | 不检查；直接计算输出和 regressor |
| `applyCoefficientDelta` | 检查 delta 是有限实向量且 tap 数匹配，然后逐 tap 相加 |
| `scaleCoefficients` | 将**全部抽头**乘以一个有限实数因子 |
| `resetState` | 恢复 `InitialCoefficients` |
| `getState` | 返回当前/初始系数与 tap 布局 |

实现见 `src/CDR/cdr_ffe.m:38-94,124-136`。

### 4.5 主抽头约束的真实边界

当前源码中：

- 构造时主抽头初值必须为 1；
- `applyCoefficientDelta` 没有强制把主抽头 delta 清零；
- `scaleCoefficients` 会缩放包括主抽头在内的所有系数。

因此：

```matlab
ffe.applyCoefficientDelta([0 0 1 0 0 0]);
```

会把默认主抽头从 1 改为 2，而不会抛错（`src/CDR/cdr_ffe.m:55-68`）。主抽头是否保持 1，取决于上层 adaptation mask 和调用策略，而不是 `cdr_ffe` 自身的运行期保护。

---

## 5. `cdr_ffe_loop`：标准 LMS / Sign-Sign LMS

### 5.1 职责

`cdr_ffe_loop` 不保存 FFE 系数。它接收：

- `cdr_ffe` 返回的 `BlockSize × TapCount` regressor；
- 调用方构造的数据判决误差；

并返回一次 block-rate 系数增量。edge sample 不参加该适配（`src/CDR/cdr_ffe_loop.m:1-5`）。

典型组合是：

```text
用 c[k] 处理 block k
    → 得到 y[k] 和 X[k]
    → 构造 error[k] = desired[k] - y[k]
    → cdr_ffe_loop 计算 delta[k]
    → block 结束后 applyCoefficientDelta
    → c[k+1] = c[k] + delta[k]
```

也就是说，本 block 的 delta 不应回溯改变本 block 输出。

### 5.2 配置和状态

构造接口：

```matlab
adapt = cdr_ffe_loop(stepSize, tapCount, mainTapIndex, blockSize, adaptEnableMask)
```

默认：

- `TapCount = 6`；
- `MainTapIndex = 3`；
- `BlockSize = 64`；
- mask 默认全开，再把主抽头位置设为 false。

`stepSize` 必须显式给出，且允许取 0（`src/CDR/cdr_ffe_loop.m:19-45,161-169`）。

状态包含：

- 当前 `StepSize`；
- tap/block 配置；
- adaptation mask；
- 最近一次 validated 更新的 gradient 和 delta；
- `UpdateCount`（`src/CDR/cdr_ffe_loop.m:7-16,100-118`）。

### 5.3 标准 LMS

定义 `errorVector` 为行向量，`X` 为 regressor：

```text
g       = (errorVector * X) / BlockSize
delta_c = StepSize * g
```

然后对所有 `AdaptEnableMask=false` 的 tap 执行：

```text
delta_c[j] = 0
```

实现见 `src/CDR/cdr_ffe_loop.m:47-66`。

误差符号约定由调用方决定。仓库当前 FFE adaptation 路径采用：

```text
error = desired - output
```

因此源码中的 `+ mu * gradient` 是与该误差定义配套的更新方向。

### 5.4 Sign-Sign LMS

SS-LMS 只保留误差和 regressor 的符号：

```text
g_ss    = (sign(errorVector) * sign(X)) / BlockSize
delta_c = StepSize * g_ss
```

MATLAB `sign(0)=0`，所以零误差或零 regressor 项不贡献梯度。实现见 `src/CDR/cdr_ffe_loop.m:68-92`。

### 5.5 Validated 与 Fast API

| API | 输入检查 | 更新诊断状态 |
|---|---:|---:|
| `update` | 是 | 是 |
| `updateFast` | 否 | 否 |
| `updateSsLms` | 是 | 是 |
| `updateSsLmsFast` | 否 | 否 |

Validated 路径要求：

- regressor 尺寸严格等于 `BlockSize × TapCount`；
- error 是长度等于 `BlockSize` 的实数有限向量；
- 输入被转换成 double，error 被统一成行向量（`src/CDR/cdr_ffe_loop.m:47-57,68-83,143-159`）。

### 5.6 主抽头 mask

默认构造确实将主抽头 mask 设为 false（`src/CDR/cdr_ffe_loop.m:33-36`），标准 LMS 和 SS-LMS 也都会按 mask 清零 delta（`src/CDR/cdr_ffe_loop.m:63-65,89-91`）。

但当前配置校验中，禁止主抽头自适应的检查已被注释；自定义 `true(1,tapCount)` mask 是合法配置（`src/CDR/cdr_ffe_loop.m:130-140`）。因此准确表述是：

> 默认 mask 冻结主抽头；底层类允许调用方显式开启主抽头适配。

---

## 6. `dlev_loop`：PAM4 判决电平双环

### 6.1 目标

PAM4 四电平按正负对称折叠成两个正幅度：

- `DLevInner`：对应 `±inner`；
- `DLevOuter`：对应 `±outer`。

正侧判决门限：

```text
Threshold = (DLevInner + DLevOuter) / 2
```

整组 slicer 门限为：

```text
[-Threshold, 0, +Threshold]
```

见 `src/CDR/dlev_loop.m:11-20`。

该类不自行切片。调用方需要给出：

- 带符号判决 `d`；
- 判决误差 `e = x-d`。

设计意图是 MMPD 与 dLev 使用同一个上层 slicer 产生的判决（`src/CDR/dlev_loop.m:4-9`）。

### 6.2 配置和状态

构造接口：

```matlab
dlev = dlev_loop(stepSize, blockSize, levelsInner, levelsOuter, polarity)
```

默认：

- block size 64；
- inner 初值 1；
- outer 初值 3；
- polarity `+1`；
- step size 必须由调用方给出。

见 `src/CDR/dlev_loop.m:47-71`。

状态包含：

- 当前内/外电平；
- 当前 threshold；
- 更新后的内/外电平轨迹；
- 各环 block error 轨迹；
- update count（`src/CDR/dlev_loop.m:30-44,106-134`）。

### 6.3 样本分类与折叠误差

当前判决 `d[i]` 通过**精确相等**分到内环或外环：

```text
isInner[i] = (abs(d[i]) == DLevInner)
isOuter[i] = (abs(d[i]) == DLevOuter)
```

折叠误差：

```text
foldedError[i] = sign(d[i]) * e[i]
```

当 `e = x - d` 且判决符号正确时：

```text
sign(d) * (x - d) = abs(x) - abs(d)
```

分环误差为：

```text
innerError[i] = foldedError[i] * isInner[i]
outerError[i] = foldedError[i] * isOuter[i]
```

实现见 `src/CDR/dlev_loop.m:151-163`。

### 6.4 全精度 LMS

```text
g_inner = sum(innerError) / BlockSize
g_outer = sum(outerError) / BlockSize

DLevInner_next = DLevInner + StepSize * Polarity * g_inner
DLevOuter_next = DLevOuter + StepSize * Polarity * g_outer
```

更新后重新计算 threshold（`src/CDR/dlev_loop.m:165-180`）。

注意分母固定为完整 `BlockSize`，不是该类样本数。因此这里统计的是“该环误差对整个 block 的平均贡献”，某类 symbol 在 block 中越少，该环当块的有效更新越小。

### 6.5 Sign-Sign LMS

SS-LMS 对分环误差逐样本取符号：

```text
g_inner_ss = sum(sign(innerError)) / BlockSize
g_outer_ss = sum(sign(outerError)) / BlockSize
```

其余更新与全精度版本相同（`src/CDR/dlev_loop.m:83-90`）。

### 6.6 普通版和 Fast 版的真实区别

| API | 更新 dLev | 更新 count | 记录 trace | 完整输入校验 |
|---|---:|---:|---:|---:|
| `dlevLms` | 是 | 是 | 是 | 否 |
| `dlevLmsFast` | 是 | 是 | 否 | 否 |
| `dlevSsLms` | 是 | 是 | 是 | 否 |
| `dlevSsLmsFast` | 是 | 是 | 否 | 否 |

因此这里的普通版/Fast 版应理解为 **traced / non-traced**，而不是 validated / unvalidated。

### 6.7 重要边界

当前源码没有强制检查：

- blockSize 为正整数；
- stepSize 有限且为正；
- polarity 严格为 `±1`；
- `d/e` 同形、长度等于 blockSize、为有限实数；
- `DLevInner < DLevOuter`；
- 电平保持正数；
- threshold 或状态饱和。

此外，环归属使用 `abs(d) == current dLev` 的浮点精确相等（`src/CDR/dlev_loop.m:154-162`）。调用方应直接用当前 dLev 生成 `d`；若传固定 `±1/±3` 而 dLev 已移动，样本可能不命中任何环，更新变成零。

---

## 7. `cdr_pd`：BBPD 和 MMPD

### 7.1 状态与输出

配置：

- `Mode = 'nrz' | 'pam4'`；
- `Polarity = +1 | -1`；
- Fast 路径使用隐藏的数值 `ModeId`。

唯一动态/调试状态是 `LastOutput`；PD 不保存跨 block 的 previous symbol 或 previous error（`src/CDR/cdr_pd.m:1-18,169-213`）。

所有 PD 输出都是：

- `phaseDecision`：`int8`，取值 `-1/0/+1`；
- `valid`：逻辑数组；
- validated 路径额外返回并保存完整 output snapshot。

### 7.2 NRZ BBPD

输入：`D[n-1]`、`E[n]`、`D[n]`，码值均为 0/1。

```text
valid = (D[n-1] != D[n])
early = valid && (E[n] == D[n-1])
```

默认 polarity 为 `+1` 时：

- early → `+1`；
- late → `-1`；
- 无 data transition → `0`。

实现见 `src/CDR/cdr_pd.m:36-49,73-93`。

### 7.3 PAM4 BBPD

PAM4 symbol code 为 `0..3`。BBPD 只接受对称跳变：

```text
outer: 0 <-> 3
inner: 1 <-> 2
```

```text
valid = outerTransition || innerTransition
early = valid && ((E != 0) == (Dprev >= 2))
```

实现见 `src/CDR/cdr_pd.m:78-93`。

因此 PAM4 BBPD 的 transition mask 与默认 MMPD 不同，不能把二者统称成同一个 PAM4 PD 规则。

### 7.4 PAM4 MMPD

MMPD 输入：

```text
dataPrev, errorPrev, dataCurr, errorCurr
```

要求 adjacent error bit 相同：

```text
sameError = (errorPrev == errorCurr)
```

默认 `transitionFilter=false`：所有非静态 PAM4 跳变均可参与；

```text
dataTransition = (dataPrev != dataCurr)
```

当 `transitionFilter=true`：只保留 `0↔3` 和 `1↔2`。

再定义：

```text
rising = (dataCurr > dataPrev)
early  = valid && ((!rising && errorHigh) || (rising && !errorHigh))
```

其中 `errorHigh=(errorPrev~=0)`。最终统一输出幅度 `-1/0/+1`，没有对称跳变 `2×` 权重（`src/CDR/cdr_pd.m:95-166`）。

SS-MMPD 不是另一个独立 API。当前 v3 的做法是把 sign-derived PAM4 symbol/error bit 输入 `mmpdFast(...,false)`，复用这个统一权重内核。

### 7.5 Validated / Fast

| API | 检查码值/尺寸 | 检查 mode/filter | 更新 `LastOutput` |
|---|---:|---:|---:|
| `bbpd` | 是 | 是 | 是 |
| `bbpdFast` | 否 | 否 | 否 |
| `mmpd` | 是 | 是 | 是 |
| `mmpdFast` | 否 | 否 | 否 |

Fast API 假设调用方已经保证输入合法。特别是 `mmpdFast` 不会像 `mmpd` 那样拒绝 NRZ mode（`src/CDR/cdr_pd.m:95-166`）。

### 7.6 跨 block 状态

PD 自身无 previous-symbol / previous-error 状态。BBPD 调用方必须构造：

```text
dataPrev = [lastSymbolOfPreviousBlock, dataCurr(1:end-1)]
```

当前 `cdr_top` 已负责 BBPD 的 previous symbol（`src/CDR/cdr_top.m:93-103,218-231`）。

MMPD 还需要 previous error；当前 `cdr_top` 没有该状态，因此 MMPD 仍由外层 runner 手工维护。

---

## 8. `cdr_voter`：block 内投票

### 8.1 配置

```matlab
voter = cdr_voter(mode, blockSize, constantMagnitude)
```

默认：

- `mode='linear'`；
- `blockSize=64`；
- `constantMagnitude=8`。

`BlockSize` 和 `ConstantMagnitude` 保存为 `int16`，且必须是 `1..32767` 的整数（`src/CDR/cdr_voter.m:24-41,109-120`）。

### 8.2 算法

净票数与两种输出模式：

```text
V = sum(int16(phaseDecision))

linear:
    phaseError = V

constant:
    V > 0  -> phaseError = +K
    V < 0  -> phaseError = -K
    V == 0 -> phaseError = 0
```

实现见 `src/CDR/cdr_voter.m:43-66`。

PD 已经把无效 transition 的 decision 置零，所以 voter 不需要单独接收 `valid` mask。

### 8.3 状态和接口

voter 没有跨 block 动态状态：

- `vote`：检查输入是长度等于 blockSize 的 `-1/0/+1` 实数向量；
- `voteFast`：不检查；
- `setMode`：运行时切换 linear/constant。

见 `src/CDR/cdr_voter.m:43-107`。

输出是 `int16`。linear 模式使用 native `int16` sum；block size 上限同时保证合法净票数不越过 int16 范围。

---

## 9. `cdr_loop`：比例—积分环路滤波器

### 9.1 配置和状态

构造接口：

```matlab
loop = cdr_loop(Kp, Ki, frequencyMin, frequencyMax, maxDeltaCode)
```

- `Kp`、`Ki` 必须显式给出；
- integral state 默认无上下限；
- `MaxDeltaCode` 默认 1，也可设为正整数或 `Inf`（`src/CDR/cdr_loop.m:44-68,128-140`）。

动态状态：

- `FrequencyState`：积分支路；
- `CodeResidue`：不足一个整数 code 的小数余量；
- `PendingCode`：已经整数化、但被 slew limit 阻止的 backlog；
- 最近一次 control、raw delta、applied delta（`src/CDR/cdr_loop.m:25-41`）。

### 9.2 核心公式

设第 `k` block 的 voter 输出为 `e[k]`。

积分状态先更新并限幅；当前控制量使用**更新后的**积分状态：

```text
F[k] = clip(F[k-1] + Ki * e[k], FrequencyMin, FrequencyMax)
u[k] = Kp * e[k] + F[k]

residueAccum = R[k-1] + u[k]
rawDelta[k]  = fix(residueAccum)       // 向零取整
pendingAccum = P[k-1] + rawDelta[k]
delta[k]     = clip(pendingAccum, -MaxDeltaCode, +MaxDeltaCode)

R[k] = residueAccum - rawDelta[k]
P[k] = pendingAccum - delta[k]
```

实现见 `src/CDR/cdr_loop.m:77-99`。

### 9.3 为什么同时需要 `CodeResidue` 和 `PendingCode`

- `CodeResidue` 只保存绝对值小于 1 code 的小数；
- `PendingCode` 保存已经形成完整整数、但受 `MaxDeltaCode` 限制未执行的 demand。

后续反向误差会先自然抵消 backlog，再向反方向输出（`src/CDR/cdr_loop.m:85-98`）。

### 9.4 API 和边界

- `update`：检查有限实数标量；
- `updateFast`：不检查，但完整更新所有控制状态；
- `setGains`：运行时修改 Kp/Ki；
- `setFrequencyLimits`：更新限幅并把当前 integral state clamp 到新范围；
- `setMaxDeltaCode`：修改输出 slew limit；
- `resetState`：清 residue/backlog/last fields，并把 0 投影到合法 integral range。

见 `src/CDR/cdr_loop.m:70-168`。

`deltaCode` 是**数值上为整数的 double**，不是 MATLAB integer class；`cdr_pi` 检查的是整数值，因此接口兼容。

当前 `PendingCode` 没有独立上限。持续需求超过 PI slew 能力时，backlog 可以持续增长。

---

## 10. `cdr_pi`：PI code、UI slip 与采样索引

### 10.1 配置

```matlab
piModel = cdr_pi(NumBit, SamplesPerSymbol)
```

默认：

- `NumBit=8`；
- `NumCode=256`；
- `SamplesPerSymbol=128`；
- 启用 `a+b=constant` 非理想相位 LUT。

见 `src/CDR/cdr_pi.m:68-100`。

运行时关键状态：

- `CodeWrapped`：当前 UI 内 PI code；
- `UiSlip`：累计跨越的完整 UI；
- wrapped/accumulated phase；
- wrapped/accumulated sample index；
- `LocalIndexFloat`：交给下游 sampler 的当前 UI 内浮点采样偏移（`src/CDR/cdr_pi.m:22-65`）。

### 10.2 Code wrap 与 UI slip

```text
rawCode         = CodeWrapped_old + deltaCode
uiDelta         = floor(rawCode / NumCode)
CodeWrapped_new = mod(rawCode, NumCode)
UiSlip_new      = UiSlip_old + uiDelta
```

见 `src/CDR/cdr_pi.m:102-145`。

使用 `floor + mod` 能正确表示负向 wrap。例如累计 code `-1` 表示为：

```text
UiSlip = -1
CodeWrapped = NumCode - 1
```

### 10.3 Phase / index 映射

```text
PhaseWrappedUI   = PhaseTableUI[CodeWrapped + 1]
PhaseAccumUI     = UiSlip + PhaseWrappedUI
IndexWrappedFloat = IndexTableFloat[CodeWrapped + 1]
IndexAccumFloat  = UiSlip * SamplesPerSymbol + IndexWrappedFloat
LocalIndexFloat  = IndexWrappedFloat
```

见 `src/CDR/cdr_pi.m:286-307`。

下游 sampler 选择 round、floor 还是 interpolation；PI 不做这个决定（`src/CDR/cdr_pi.m:234-247`）。

### 10.4 理想和默认非理想 LUT

理想 LUT：

```text
PhaseIdeal[k] = k / NumCode,  k = 0 ... NumCode-1
```

见 `src/CDR/cdr_pi.m:309-315`。

默认并不是 ideal，而是每个象限内使用 `a+b=1` 权重插值：

```text
a = 1 - localAlpha
b = localAlpha
localPhase = atan2(b, a) / (pi / 2)
```

再映射到四个象限，并强制 0/0.25/0.5/0.75 UI 边界精确（`src/CDR/cdr_pi.m:317-370`）。

接口还支持：

- `resetNonideal`：切换 ideal LUT；
- `setDefaultNonideal`：恢复 `a+b=constant`；
- `setInlTableUI`：ideal + custom INL；
- `setPhaseTableUI`：直接提供完整 phase LUT（`src/CDR/cdr_pi.m:170-225`）。

当前 custom table 只检查长度和 finite，不强制单调。因此用户提供非单调 LUT 时，code wrap / UI slip 仍按 code 计算，但相位不一定物理连续。

### 10.5 `update` 与 `updateFast`

`update`：

- 检查 `deltaCode` 是有限整数标量；
- 更新 code/slip；
- 刷新全部派生 phase/index 状态。

`updateFast`：

- 不检查；
- 只更新 `CodeWrapped` 和 `UiSlip`；
- 直接返回最新 local index；
- 不刷新对象内的 phase/index 派生属性。

见 `src/CDR/cdr_pi.m:102-146`。

因此正确 Fast 用法是：

```matlab
nextIndex = piModel.updateFast(deltaCode);
```

不要在 Fast update 后忽略返回值再调用 `getLocalIndex()`，因为对象的派生 `LocalIndexFloat` 可能仍是旧值。各 validation runner 在采样地址计算中正确地使用了 `updateFast`/`getLocalIndex` 的返回值。

---

## 11. `cdr_top`：code 域 CDR DSP core

> 2026-09-26 更新：旧的五参数组件注入构造路径
> (`cdr_top(pd, voter, loopFilter, phaseInterpolator, initialSymbol)`)、其
> `processBlock(data, edge)` / `processBlockFast` / `resetState(initialSymbol)`
> 语义以及 `PreviousSymbol`、`ConfigMode` 均已删除。`cdr_top` 现在只有单一的
> config 结构体构造路径。下文描述现状。

### 11.1 构造和对象所有权

```matlab
top = cdr_top(config)
```

`config` 必须是单个结构体，否则抛 `cdr_top:InvalidConfig`。构造函数在
`constructConfigured` 中例化并持有整条 code 域链：`cdr_pd`(MMPD)、`cdr_voter`、
`cdr_loop`、`cdr_pi`、`cdr_ffe` 及其跨块窗口、静态 PAM4 slicer、`dlev_loop`、
`cdr_ffe_loop` 与 `loop_monitor`，并在末尾同步 reset。每个配置项都必须显式提供，
缺失或非法字段抛 `cdr_top:Invalid<Field>`；`cdr_top.defaultConfig` 返回与当前 v3
对齐的起点。

### 11.2 顶层自有状态

- `BlockIndex`：已处理 block 数；
- `SampleBlockCount`：已喂入的采样块数；
- `CurrentLocalIndexFloat`：下一 block 使用的 wrapped local index；
- `PreviousDataSymbol` / `PreviousErrorBit`：跨块 MMPD 历史；
- pending 流水线状态（`PendingCentered`/`PendingPast`/`HavePending`/
  `PendingCodeWrapped`/`PendingUiSlip`/`PendingBlockIndex`）；
- `GatedCoefficients`、`LastOutput`。

### 11.3 `processBlock`

`processBlock(centeredCode)` 接收一个按时间顺序、零中心的 ADC code 块，转调
`processConfiguredBlock` 并更新 `LastOutput`。非法输入抛
`cdr_top:InvalidCenteredCode`。块内顺序严格照 v3：
FFE → slicer → MMPD → voter → loop → PI → mu 降档 → dLev → FFE gate → FFE
SS-LMS 写入。因 FFE 前置抽头的一块环路死区，流水线未填满时返回
`HasOutput = false`。

### 11.4 `flush`

`flush()` 用零 future 处理最后一个 pending 块；无 pending 时返回空输出结构。它不再
依赖任何模式判定（旧的 `cdr_top:UnsupportedFlush` 已随 config 模式判定一起删除）。

### 11.5 Reset

`resetState()` 不接收参数（旧的 `resetState(initialSymbol)` 已删除）。它 reset
PD、loop filter、PI，重配 PI 非理想表并置 `PiInitialCode`，reset 并重置 dLev、FFE、
FFE loop 的步长，reset monitor，并清空所有 pending / 顶层状态。它不改变任何配置项
(PD mode/polarity、voter mode、Kp/Ki/limits、PI 位宽与非理想 LUT)。

### 11.6 当前集成边界

`cdr_top` 仍然**不**拥有 sampler / TI ADC，也不做绝对 waveform UI 地址上的 slip
调度或 frequency detector / FLL——这些归调用方（各 validation runner）所有。它现在
**确实**在 code 域内拥有 CDR FFE 及其窗口、unified slicer、dLev 与 FFE SS-LMS 及
FFE gate monitor。类头部（`src/CDR/cdr_top.m` 顶部注释）对此有说明；配置模式的完整
行为见 `docs/ARCHITECTURE.md` 的 “`cdr_top` configured code-domain mode” 一节。


---

## 12. 建议的八模块联合 transaction

如果后续增加 waveform-level orchestrator，建议保留当前 `cdr_top` 作为数字 core，并由更外层顶层定义一个明确的 block transaction：

```text
状态进入 block k:
  phase[k], UiSlip[k], FFE coeff[k], dLev[k], previous data/error

1. 使用 phase[k] 在 waveform / TI ADC 上取样
2. 重排 ADC physical lanes 到 chronological UI 顺序
3. 组装 past + target + future FFE window
4. 使用 FFE coeff[k] 计算 output[k] 和 regressor[k]
5. 使用 dLev[k] 统一切片，得到 data/edge/error 判决
6. PD + voter + loop 计算 deltaCode[k]
7. PI 提交 phase[k+1]
8. dLev 由同一份 decision/error 计算并提交 dLev[k+1]
9. FFE loop 计算 raw delta[k]
10. 按 write-enable/freeze 策略提交 FFE coeff[k+1]
11. 提交 previous data/error 与外部缓存状态
```

需要由联合顶层统一检查：

- voter、FFE loop、dLev、ADC lane 数和 target block 长度一致；
- FFE latency 与 data/error history 对齐；
- BBPD/MMPD 模式及其不同输入；
- training / decision-directed 切换；
- coefficient write freeze；
- UI slip 对绝对 waveform 地址的作用；
- 所有模块的同步 reset。

---

## 13. 当前测试证据与已知缺口

### 13.1 2026-09-22 本次实跑结果

MATLAB R2025b：

| 测试 | 结果 | 覆盖重点 |
|---|---|---|
| `validation/CDR/test_subBlock/test_cdr_pd.m` | 13/13 PASS | NRZ/PAM4 BBPD、MMPD、filter、polarity、Fast 等价、boundary overlap、外部 slicer |
| `tests/CDR/test_cdr_voter.m` | 7/7 PASS | linear/constant、类型、行列、Fast、非法输入 |
| `tests/CDR/test_cdr_loop.m` | 10/10 PASS | PI 更新顺序、residue、integral saturation、pending、slew、Fast、PI 接口 |
| `tests/CDR/test_cdr_top.m` | 6/6 PASS | 四模块调度、当前/下一相位、overlap、reset、Fast 等价、非法输入 |
| `dlev_loop` 当前 `(d,e)` API 定向 smoke | PASS | 一次 SS-LMS block 更新；得到 inner/outer/threshold = 1.05/3.05/2.05 |
| `tests/CDR/test_cdr_ffe.m` | FAIL | 测试仍期待 `cdr_ffe:MainTapUpdate`；当前源码允许直接修改主抽头 |
| `tests/CDR/test_cdr_ffe_loop.m` | FAIL | 测试仍期待 `cdr_ffe_loop:MainTapAdaptEnabled`；当前源码允许自定义 mask 开启主抽头 |

后两项失败是**测试契约与当前源码不一致**，不是 FIR/LMS 数值断言失败：

- `tests/CDR/test_cdr_ffe.m:66-75` 期待一个当前实现不存在的运行期主抽头保护；
- `tests/CDR/test_cdr_ffe_loop.m:127-136` 期待一个已在源码中注释掉的配置限制；
- 对应实现见 `src/CDR/cdr_ffe.m:55-68` 和 `src/CDR/cdr_ffe_loop.m:130-140`。

### 13.2 dLev 测试缺口

旧脚本 `validation/CDR/test_subBlock/test_lms_loop.m` 仍按单参数调用：

```matlab
dlevLms(rxSamples)
dlevSsLms(rxSamples)
```

但当前 API 明确需要 `(d,e)`（`validation/CDR/test_subBlock/test_lms_loop.m:66-76`; `src/CDR/dlev_loop.m:73-104`）。该脚本当前不能作为有效回归，并且只有绘图，没有数值 pass/fail 断言。

### 13.3 PI 测试缺口

当前 PI 专项脚本 `test_cdr_pi_plot.m` 主要做可视化，不包含数值 assertions；而且其 repo root 只从 `test_subBlock` 向上两级，得到的是 `validation` 而非仓库根，干净 MATLAB session 下 source path 会偏一层（`validation/CDR/test_subBlock/test_cdr_pi_plot.m:18-28`）。

PI 的部分行为由 `test_cdr_loop` 和 `test_cdr_top` 间接覆盖，但仍缺少独立自动化测试：

- 正/负多 UI wrap；
- ideal / default nonideal / custom LUT；
- `updateFast` 派生状态陈旧契约；
- invalid table 和 code；
- reset 保留 LUT 配置。

### 13.4 尚未验证的系统能力

当前 sub block 和静态 deterministic validation 不足以证明：

- BER / SER；
- jitter transfer / jitter tolerance / bathtub；
- frequency offset acquisition；
- interpolating sampler；
- 噪声、PVT、lane mismatch、skew 的全系统鲁棒性；
- 与电路仿真、RTL bit-accurate fixed-point 或硅测量相关性；
- 8 个 sub block 在统一顶层中的 reset、latency 和 block-size 一致性。

---

## 14. 使用与阅读建议

### 14.1 只研究数字 BBPD 控制链

建议按以下顺序阅读：

1. `src/CDR/cdr_pd.m`
2. `src/CDR/cdr_voter.m`
3. `src/CDR/cdr_loop.m`
4. `src/CDR/cdr_pi.m`
5. `src/CDR/cdr_top.m`
6. `tests/CDR/test_cdr_top.m`

### 14.2 研究 CDR FFE adaptation

建议按以下顺序：

1. `src/CDR/cdr_ffe.m`
2. `src/CDR/cdr_ffe_loop.m`
3. `tests/CDR/test_cdr_ffe.m`
4. `tests/CDR/test_cdr_ffe_loop.m`
5. `validation/CDR/test_subBlock/test_cdr_ffe_adaptation.m`

阅读时务必注意当前两个单元测试中的主抽头异常断言已与源码不一致。

### 14.3 研究三环联合行为

`cdr_top` 不是三环 runner。需要查看：

- `validation/CDR/test_cdr_dlev_cdrffe/src/cdr_dlev_cdrffe_sslms_v3/cdr_dlev_cdrffe_sslms_v3.m`

该 runner 在外层组合：

- TI ADC / sampling；
- CDR FFE；
- slicer；
- uniform-weight MMPD（SS-MMPD）；
- dLev SS-LMS；
- FFE SS-LMS；
- phase loop；
- training、mu 切换、freeze 和结果统计。

它是 validation orchestration，不是 `src/CDR/cdr_top` 的等价实现。

---

## 15. 一页式总结

```text
src/CDR 当前实现：

cdr_ffe
  - 无缓存浮点 FIR
  - 调用方组窗口
  - 输出 y + regressor
  - 初始 main=1，但运行时不硬冻结

cdr_ffe_loop
  - 标准 LMS / SS-LMS
  - delta = mu * block-average gradient
  - 默认 mask 冻结 main，自定义 mask 可开启

 dlev_loop
  - PAM4 内/外幅度双环
  - folded error = sign(d)*(x-d)
  - threshold = (inner+outer)/2
  - traced / non-traced API，无完整 validated API

cdr_pd
  - NRZ/PAM4 BBPD
  - PAM4 binary-error MMPD
  - 输出 int8 {-1,0,+1}
  - previous symbol/error 由调用方保存

cdr_voter
  - linear：保留净票数
  - constant：只保留符号，输出 ±K/0
  - 无跨 block 状态

cdr_loop
  - PI filter
  - 浮点 integral + residue
  - integer-valued delta
  - slew backlog 独立放 PendingCode

cdr_pi
  - wrapped code + UiSlip
  - 默认 a+b=constant 非理想 LUT
  - 输出浮点 local sample index
  - Fast 返回值最新，但派生 debug state 可陈旧

cdr_top
  - 当前只集成 BBPD → voter → loop → PI
  - 保存 previous symbol
  - block k 用旧相位，block k+1 用新相位
  - 未集成 FFE、dLev、MMPD、ADC、slicer、FLL
```
