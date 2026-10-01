# fx_range_census 实现说明与结论

生成日期: 2026-10-01
对应结果: `result/fx_range_census/fx_range_census.txt` / `.csv`
分支: `feat/ppm-fixed-point`

## 1. 验证目标与整体结构

定点化的第 0 步。目标不是改任何模型，而是**用真实运行数据给每个节点定字长**。

被测对象是 ppm 三环套件已经产出的 result MAT（`test_cdr_three_loop_wi_ppm/result/`
下 `cdr_three_loop_ppm_{p100,p0,m100}`，各 **32 相位 × 15000 block**）。本脚本
**不跑任何仿真**，只读 MAT 做统计，因此零仿真成本、可随时重跑。

判据不是通过/失败，而是产出一张"节点 → (signed, WordLength, FractionLength)"的表，
作为后续定点实现的唯一真相源。

## 2. 关键实现要点与设计取舍

### 2.1 整数位与小数位必须分开定，依据完全不同

- **整数位**由动态范围决定：`ceil(log2(absmax)) + 1`，额外那 1 bit 是捕获期瞬态余量。
- **小数位**由**最小有效增量**决定，不是由范围决定。

第二条是这一步存在的全部理由。对 FFE 系数、dLev 这类自适应量，如果 LSB 粗于单块
更新量，累加器会直接进入**死区停摆** —— 环路看上去"收敛"了，实际是冻住了。这种
失效在波形上几乎看不出来，只能靠事先按增量定字长来避免。

实现上取逐块增量 `|diff(trace, 1, 2)|` 的非零值的 **1% 分位**（避开数值噪声），
再留 **3 bit 余量**（约 8 倍）。

### 2.2 FFE 主抽头必须单独统计

主抽头被四层硬冻结为恒等于 1（`cdr_ffe.m:86-88` / `:130-133`、
`cdr_ffe_loop.m:146-148`、`cdr_top.m:472-480`）。它与其余抽头量纲完全不同：
**它根本不需要乘法器，是一根直通到加法器的线**。

若把 6 个抽头混在一起取包络，非主抽头的字长会被主抽头的 1.0 平白拉大 2 bit。
因此脚本按 `FfeInitCoefficients == 1` 定位主抽头并单独成行。

### 2.3 跨工况取最坏值

字长必须同时覆盖 +100 / 0 / −100 ppm 三种工况，所以汇总时对范围取并集、对最小
增量取最小值。

## 3. 本次运行配置

- 数据来源：`cdr_three_loop_ppm_{p100,p0,m100}/cdr_three_loop_ppm_result.mat`
- 规模：每组 32 相位 × 15000 block，共 23 个节点
- 无参运行：`fx_range_census()`

## 4. 关键结果与结论

完整表见 `result/fx_range_census/fx_range_census.txt`。要点：

### 4.1 推翻了三个先前的估计

| 节点 | 先前估计 | 实测 | 影响 |
|---|---|---|---|
| FFE 非主抽头累加器 | 小数 20 位 | 最小增量 **3.12e-06** → 小数 **22** 位，总 **24** 位 | 估少 2 bit，按原估计会停摆 |
| `FrequencyState` | 整数 3 位（按 `FrequencyLimit=4`） | 实测仅 **−0.928 ~ +0.838** → 整数 **1** 位 | 可省 2 bit |
| `PendingCode` | ±8000（按 +130ppm 饱和实测） | 本三组仅 **−66 ~ +5** | 见 4.3 |

`FrequencyState` 那条要注意**取样偏差**：这三组都是锁定成功的运行，积分器从未
撞到 ±4 钳位。失败/饱和场景不在数据里，所以整数位不能真的按 1 位定，需要保留
到钳位值。这是数据驱动定字长的固有风险，必须显式记下来。

### 4.2 voter 的除法确认可以消掉

`PhaseError_Voter` 实测范围只有 **−0.219 ~ +0.188**，因为 `mean` 模式除以了 64。
乘回 64 后是 **−14 ~ +12**，正好与 `EdgeCountPerBlock`（**0 ~ 22**，`TransitionFilter=1`
对称跳变下每块约 16 个事件）同量级。

这确认了此前的判断：**把 1/64 折进 `Kp`/`Ki`，`phaseError` 退化为小整数**，
可以省掉一个除法器，且数学上严格等价。

另需注意 `EdgeCountPerBlock` 的**最小值是 0** —— 存在零事件的块，定点实现必须
显式处理"本块无更新"，不能依赖除法的自然行为。

### 4.3 `PendingCode` 的钳位值是一个待决策项

浮点模型里它无界增长。本三组（均锁定成功）只到 −66，但历史记录显示 +130 ppm
slew 饱和时可达 5408~7883。

问题在于 `loop_monitor` 的 slew 饱和守卫**正是读它**
（`mean|PendingCode| >= SlewSatPendingTol`）。钳位会改变饱和特征，所以钳位值
不能随手定，必须与守卫阈值一起重新标定。**本步只记录，不决策。**

### 4.4 其余节点

- `AdcCodeEnvelope` ±48，与 7-bit ADC 的 ±64 满量程自洽（dLev outer 初值 48）。
- `UnwrappedPhase` ±12167、`DriftSample` ±12287 → 均需 15 位整数。
- `DlevInner/Outer/Threshold` 最小增量 1.56e-4 ~ 3.12e-4 → 小数 15~16 位。
- `CodeResidue` 严格落在 ±1，与其"只保留不足一个 code 的小数部分"的定义吻合。
- `DeltaCode` 恒在 ±1，与 `MaxDeltaCode=1` 吻合。

## 5. 复现方法

```matlab
cd validation/CDR/test_cdr_fixed_point
setup_cdr_fixed_point_paths();
fx_range_census();                       % 无参，读三组 ppm MAT，写 result/fx_range_census/
fx_range_census('SaveOutputs', false);   % 只打印不落盘
```

前提是 `test_cdr_three_loop_wi_ppm/result/` 下三组 result MAT 存在（它们被
`.gitignore` 排除，需本地先跑过 ppm 套件）。缺失的工况会告警并跳过，不会中断。

## 6. 遗留与下一步

1. `FrequencyState` 的整数位需按钳位值而非实测值定，避免取样偏差。
2. `PendingCode` 钳位值与 slew 饱和守卫阈值需一起标定。
3. 纯范围类节点（表中标 TBD）的小数位应由物理分辨率决定，整数码节点为 0。
4. 下一步是把这张表固化成 `docs/CDR_FIXED_POINT.md` 的 Q 格式契约，
   再按"时序链 → dLev → FFE → loop_monitor"的顺序逐块实现。
