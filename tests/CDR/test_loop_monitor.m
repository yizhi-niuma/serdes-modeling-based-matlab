function test_loop_monitor
%TEST_LOOP_MONITOR Regression checks for the causal CDR loop policy detectors.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
suiteRoot = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe');
addpath(suiteRoot);
setup_cdr_dlev_cdrffe_paths();

testSnrSettleRejectsClosedEyeTransients();
testSnrSettleDisabledAndInvalidInputs();
testFrequencyStateLockStatic();
testRotationPeriodLockStatic();
testFreqStateEwma();

fprintf('test_loop_monitor passed 5 / 5 checks.\n');
end

function testSnrSettleRejectsClosedEyeTransients()
% 眼质量换挡判据必须拒绝"闭眼但瞬时读数很好"的序列。
%
% 这条序列是实测签名：-100 ppm 冷启动、全部起始相位都没锁上的那次运行，逐 block
% 判决导向 SNR 的中位数只有 10.6 dB，但最大值达到 26.6 dB、p99 达到 22.5 dB——
% 积分绕到钳位后 PI 持续旋转，采样点周期性扫过眼心就会给出漂亮的单块读数。
% 因此逐块直接判阈必然误触发，平滑是判据的必要组成部分而非修饰。
thresholdDb = 15;
alpha = 1 / 128;
minBlock = 200;

closedEyeBaseline = 10;
closedEyeSpike = 26;
spikePeriod = 20;
closedEyeBlocks = 3000;

closedEye = closedEyeBaseline * ones(1, closedEyeBlocks);
closedEye(spikePeriod:spikePeriod:closedEyeBlocks) = closedEyeSpike;
% 前提确认：逐块判阈确实会在这条序列上误触发。
assert(max(closedEye) >= thresholdDb, ...
    'The fixture must contain single-block readings above the threshold.');

monitor = loop_monitor();
assert(~monitor.getState().SnrSettleEnabled);
monitor.enableSnrSettle(thresholdDb, alpha, minBlock);
state = monitor.getState();
assert(state.SnrSettleEnabled && state.SnrSettleThresholdDb == thresholdDb);
assert(state.SnrSettleAlpha == alpha && state.SnrSettleMinBlock == minBlock);
assert(isnan(state.SnrEwmaDb) && ~state.SnrSettleDone);
assert(isnan(state.SnrSettleBlock));

for block = 1:closedEyeBlocks
    assert(~monitor.updateSnrSettle(block, closedEye(block)), ...
        'A closed eye with good single-block readings must not settle.');
end
assert(~monitor.SnrSettleDone && isnan(monitor.SnrSettleBlock));
assert(monitor.SnrEwmaDb < thresholdDb);

% 非有限读数(无有效样本或误差功率恰为 0)必须被跳过,不得改变均值。
ewmaBefore = monitor.SnrEwmaDb;
assert(~monitor.updateSnrSettle(closedEyeBlocks + 1, Inf));
assert(~monitor.updateSnrSettle(closedEyeBlocks + 2, NaN));
assert(monitor.SnrEwmaDb == ewmaBefore);

% 眼张开后必须触发,且只触发一次。
openEyeDb = 22;
triggerBlock = NaN;
for block = closedEyeBlocks + 3:closedEyeBlocks + 1000
    triggered = monitor.updateSnrSettle(block, openEyeDb);
    if triggered
        assert(isnan(triggerBlock), 'The SNR settle detector fired twice.');
        triggerBlock = block;
    end
end
assert(~isnan(triggerBlock), 'The SNR settle detector never fired.');
assert(monitor.SnrSettleDone && monitor.SnrSettleBlock == triggerBlock);
assert(monitor.SnrEwmaDb >= thresholdDb);

for block = triggerBlock + 1:triggerBlock + 10
    assert(~monitor.updateSnrSettle(block, openEyeDb));
end
assert(monitor.SnrSettleBlock == triggerBlock);

% minBlock 必须压住早期触发,即使读数一直在阈值之上。
early = loop_monitor();
early.enableSnrSettle(thresholdDb, 1, 50);
for block = 1:49
    assert(~early.updateSnrSettle(block, openEyeDb));
end
assert(early.SnrEwmaDb >= thresholdDb && ~early.SnrSettleDone);
assert(early.updateSnrSettle(50, openEyeDb));
assert(early.SnrSettleBlock == 50);
end

function testSnrSettleDisabledAndInvalidInputs()
% 未显式 enableSnrSettle 前必须拒绝调用；配置参数校验风格与频率态门控一致。
monitor = loop_monitor();
assertThrowsId(@() monitor.updateSnrSettle(1, 10), ...
    'loop_monitor:SnrSettleDisabled');

assertThrowsId(@() monitor.enableSnrSettle(15, 0.1), ...
    'loop_monitor:InvalidSnrSettleConfig');
assertThrowsId(@() monitor.enableSnrSettle(Inf, 0.1, 10), ...
    'loop_monitor:InvalidSnrSettleThreshold');
assertThrowsId(@() monitor.enableSnrSettle(15, 0, 10), ...
    'loop_monitor:InvalidSnrSettleAlpha');
assertThrowsId(@() monitor.enableSnrSettle(15, 1.5, 10), ...
    'loop_monitor:InvalidSnrSettleAlpha');
assertThrowsId(@() monitor.enableSnrSettle(15, 0.1, 0), ...
    'loop_monitor:InvalidSnrSettleMinBlock');

monitor.enableSnrSettle(15, 0.1, 10);
assertThrowsId(@() monitor.updateSnrSettle(0, 10), 'loop_monitor:InvalidBlock');
assertThrowsId(@() monitor.updateSnrSettle(1, 'x'), 'loop_monitor:InvalidSnr');
assertThrowsId(@() monitor.updateSnrSettle(1, [1 2]), 'loop_monitor:InvalidSnr');
end

function testFrequencyStateLockStatic()
% 频偏跟踪的频率态平坦判据：尾窗均值恒定（前后半均值一致、std 小）且量级
% 匹配期望速率才算锁定。量级匹配对符号不敏感，避免采样/PD 极性约定影响判定。
window = 200;
expectedRate = -0.8192;

flat = expectedRate + 0.002 * sin((1:600) / 7);
[locked, diag] = loop_monitor.judgeFreqStateGateOffline(flat, window, ...
    expectedRate, 0.05, 0.05, 0.1);
assert(locked);
assert(abs(diag.MeanValue - expectedRate) < 0.05);
assert(diag.FlatnessOk && diag.RateOk);

% 仍在牵引（尾窗持续爬升）-> 未锁定（前后半均值差过大）。
ramp = linspace(-0.2, -0.8192, 600);
assert(~loop_monitor.judgeFreqStateGateOffline(ramp, window, expectedRate, ...
    0.05, 0.05, 0.1));

% 平坦但数值错误（仍在 0 附近）-> 平坦通过但量级不匹配 -> 未锁定。
wrong = 0.001 * cos((1:600) / 5);
[lockedWrong, diagWrong] = loop_monitor.judgeFreqStateGateOffline(wrong, ...
    window, expectedRate, 0.05, 0.05, 0.1);
assert(~lockedWrong && diagWrong.FlatnessOk && ~diagWrong.RateOk);

% 幅度匹配对符号不敏感：+0.8192 平坦也通过量级检查。
[lockedPos, diagPos] = loop_monitor.judgeFreqStateGateOffline(-flat, window, ...
    expectedRate, 0.05, 0.05, 0.1);
assert(lockedPos && diagPos.RateOk);

% 序列长度不足窗口 -> 未锁定。
assert(~loop_monitor.judgeFreqStateGateOffline(flat(1:100), window, ...
    expectedRate, 0.05, 0.05, 0.1));

% 期望速率关闭（NaN/Inf）只看平坦度。
assert(loop_monitor.judgeFreqStateGateOffline(wrong, window, NaN, ...
    0.05, 0.05, Inf));

assertThrowsId(@() loop_monitor.judgeFreqStateGateOffline([1 2 NaN], 2, ...
    0, 0.1, 0.1, 0.1), 'loop_monitor:InvalidFreqSeq');
assertThrowsId(@() loop_monitor.judgeFreqStateGateOffline([1 2 3], 0, ...
    0, 0.1, 0.1, 0.1), 'loop_monitor:InvalidWindowBlocks');
end

function testRotationPeriodLockStatic()
% PI 旋转周期恒定 => 已跟踪。用恒定斜率合成 unwrapped，UI slip 等间隔出现；
% 恒定序列（0 ppm 无旋转）或不规则旋转都判未锁定。
window = 2000;
codesPerUi = 128;
rate = 0.8192;
expectedPeriod = codesPerUi / rate;
k = 1:4000;

unwrapped = round(1000 - rate * k);
[locked, diag] = loop_monitor.detectRotationPeriodLock(unwrapped, window, ...
    codesPerUi, 6, 0.05, expectedPeriod, 5);
assert(locked);
assert(abs(diag.PeriodMean - expectedPeriod) < 5);
assert(diag.PeriodCov < 0.05 && diag.DispersionOk && diag.PeriodOk);

% 恒定（无 slip 事件）-> 未锁定。
constant = 7 * ones(1, 4000);
[lockedConst, diagConst] = loop_monitor.detectRotationPeriodLock(constant, ...
    window, codesPerUi, 6, 0.2, NaN, Inf);
assert(~lockedConst && diagConst.EventCount == 0);

% 不规则旋转（周期抖动大）-> 未锁定。
irregular = round(1000 - rate * k - 40 * sin(k / 11));
assert(~loop_monitor.detectRotationPeriodLock(irregular, window, ...
    codesPerUi, 6, 0.05, expectedPeriod, 5));

% 周期匹配关闭（NaN/Inf）时只看离散度。
assert(loop_monitor.detectRotationPeriodLock(unwrapped, window, ...
    codesPerUi, 6, 0.05, NaN, Inf));

assertThrowsId(@() loop_monitor.detectRotationPeriodLock([1 2 3], 2, 1, ...
    1, 0.1, NaN, Inf), 'loop_monitor:InvalidCodesPerUi');
assertThrowsId(@() loop_monitor.detectRotationPeriodLock([1 2 Inf], 2, ...
    128, 1, 0.1, NaN, Inf), 'loop_monitor:InvalidUnwrappedSeq');
end

function testFreqStateEwma()
% EWMA 版频率态判据（freqStateLockCoreEWAM）与在线门控（enable/updateFreqEwmaGate）。
% 关键不变量：在线逐块闩锁块 == 离线整条回放 diag.LatchBlock（二者按构造一致）。
expectedRate = -0.8192;
tolHalf = 0.03;
tolStd = 0.08;
tolRate = 0.12;
sat = 3.6;
dwell = 300;
aF = 1 / 64;
aS = 1 / 512;
aM = 1 / 256;

rng(42, 'twister');
flat = expectedRate + 0.004 * randn(1, 6000);
seqLock = [linspace(0, expectedRate, 1500), flat];

% 1) 真锁序列判锁，诊断字段齐备且均值匹配期望速率。
[locked, lockDiag] = loop_monitor.freqStateLockCoreEWAM(seqLock, ...
    expectedRate, tolHalf, tolStd, tolRate, sat, dwell, aF, aS, aM);
assert(locked, 'EWMA 应判真锁序列为锁定。');
assert(isfinite(lockDiag.LatchBlock) && lockDiag.LatchBlock > 0);
assert(abs(lockDiag.MeanValue - expectedRate) <= tolRate);

% 2) 慢漂移 ramp 永不判锁。
assert(~loop_monitor.freqStateLockCoreEWAM( ...
    linspace(0, 2 * expectedRate, 8000), expectedRate, tolHalf, tolStd, ...
    tolRate, sat, dwell, aF, aS, aM));

% 3) railed（恒 -4，|x| >= sat）被饱和轴否决，不判锁。
assert(~loop_monitor.freqStateLockCoreEWAM(-4 * ones(1, 8000), ...
    expectedRate, tolHalf, tolStd, tolRate, sat, dwell, aF, aS, aM));

% 4) 速率轴：NaN 期望速率旁路后，错斜率的平坦序列也判锁；带速率轴时被拒。
wrongFlat = [linspace(0, -1.79, 1500), (-1.79) + 0.004 * randn(1, 6000)];
assert(loop_monitor.freqStateLockCoreEWAM(wrongFlat, NaN, tolHalf, tolStd, ...
    Inf, sat, dwell, aF, aS, aM));
assert(~loop_monitor.freqStateLockCoreEWAM(wrongFlat, expectedRate, ...
    tolHalf, tolStd, tolRate, sat, dwell, aF, aS, aM));

% 5) 在线门控逐块闩锁块必须等于离线 LatchBlock。
mon = loop_monitor();
mon.enableFreqEwmaGate(expectedRate, tolHalf, tolStd, tolRate, 1, sat, ...
    dwell, aF, aS, aM);
onlineLatch = NaN;
for k = 1:numel(seqLock)
    if mon.updateFreqEwmaGate(k, seqLock(k)) && isnan(onlineLatch)
        onlineLatch = k;
    end
end
assert(onlineLatch == lockDiag.LatchBlock, ...
    'online latch %d must equal offline LatchBlock %d', onlineLatch, ...
    lockDiag.LatchBlock);
assert(mon.FreqGateBlock == onlineLatch);

% 6) 未启用即调用、以及非法 alpha，均应报错。
mon2 = loop_monitor();
assertThrowsId(@() mon2.updateFreqEwmaGate(1, 0), ...
    'loop_monitor:FreqEwmaDisabled');
assertThrowsId(@() mon2.enableFreqEwmaGate(expectedRate, tolHalf, tolStd, ...
    tolRate, 1, sat, dwell, 1.5, aS, aM), 'loop_monitor:InvalidAlpha');

% 7) 非有限样本被跳过并计数，不污染 EWMA。
mon3 = loop_monitor();
mon3.enableFreqEwmaGate(expectedRate, tolHalf, tolStd, tolRate, 1, sat, ...
    dwell, aF, aS, aM);
mon3.updateFreqEwmaGate(1, NaN);
assert(mon3.FreqGateSkippedCount == 1);

fprintf(['  testFreqStateEwma: online latch=%d == offline, ' ...
    'ramp/rail/wrong-rate rejected, skip counted OK\n'], onlineLatch);
end

function assertThrowsId(testFcn, expectedId)
didThrow = false;
try
    testFcn();
catch err
    didThrow = true;
    assert(strcmp(err.identifier, expectedId), ...
        'Expected error %s, received %s.', expectedId, err.identifier);
end
assert(didThrow, 'Expected error %s was not thrown.', expectedId);
end
