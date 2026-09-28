function test_loop_monitor
%TEST_LOOP_MONITOR Regression checks for the causal CDR loop policy detectors.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
suiteRoot = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe');
addpath(suiteRoot);
setup_cdr_dlev_cdrffe_paths();

testStartAndQualificationBoundaries();
testExactProductionThresholds();
testLatchedCenterAndModeTie();
testEventDefinitionsAndBandExit();
testResetStartsFreshNextBlock();
testPermanentFreeze();
testCausalityAndIndependentInstances();
testUnwrappedCodesRemainDistinct();
testInvalidInputs();
testSnrSettleRejectsClosedEyeTransients();
testSnrSettleDisabledAndInvalidInputs();
testFrequencyStateLockStatic();
testRotationPeriodLockStatic();

fprintf('test_loop_monitor passed 15 / 15 checks.\n');
end

function testStartAndQualificationBoundaries()
monitor = loop_monitor(3, 1, 1, 4);
for block = 1:3
    assert(~monitor.update(5, block));
end
state = monitor.getState();
assert(state.ModeOccurrences == 0 && isempty(state.SearchCodes));
assert(isnan(state.CenterUnwrapped) && state.LastBlock == 3);

assert(~monitor.update(5, 4));
assert(~monitor.update(5, 5));
assert(isnan(monitor.getState().CenterUnwrapped));
assert(~monitor.update(5, 6));
state = monitor.getState();
assert(state.CenterUnwrapped == 5);
assert(state.CandidateStartBlock == 6);
assert(state.ModeOccurrences == 3 && state.EventCount == 0);
assert(~monitor.update(4, 7));             % center departure
assert(monitor.update(5, 8));              % noncenter-to-center touch
assert(monitor.Frozen && monitor.FreezeBlock == 8);
end

function testExactProductionThresholds()
monitor = loop_monitor(100, 50, 3, 1);
for block = 1:99
    assert(~monitor.update(7, block));
end
assert(isnan(monitor.CenterUnwrapped));
assert(~monitor.update(7, 100));
state = monitor.getState();
assert(state.CenterUnwrapped == 7 && state.ModeOccurrences == 100);
assert(state.EventCount == 0 && state.CandidateStartBlock == 100);

for event = 1:49
    departureBlock = 100 + 2 * event - 1;
    assert(~monitor.update(8, departureBlock));
    assert(~monitor.update(7, departureBlock + 1));
end
state = monitor.getState();
assert(~state.Frozen && state.EventCount == 49);
assert(~monitor.update(8, 199));
assert(monitor.update(7, 200));
state = monitor.getState();
assert(state.Frozen && state.EventCount == 50);
assert(state.FreezeBlock == 200 && state.ModeOccurrences == 150);
end

function testLatchedCenterAndModeTie()
monitor = loop_monitor(4, 20, 3, 1);
feed(monitor, [11 12 12 11], 1);
state = monitor.getState();
assert(isnan(state.CenterUnwrapped));
assert(state.SearchModeUnwrapped == 11);   % equal counts choose lower code
assert(isequal(sort(state.SearchCodes), [11 12]));

assert(~monitor.update(12, 5));
assert(~monitor.update(12, 6));
state = monitor.getState();
assert(state.CenterUnwrapped == 12 && state.ModeOccurrences == 4);
feed(monitor, [11 11 11 12 11], 7);
state = monitor.getState();
assert(state.CenterUnwrapped == 12);       % later distribution cannot move it
assert(state.ModeOccurrences == 5);       % only later center samples increment
end

function testEventDefinitionsAndBandExit()
monitor = loop_monitor(3, 99, 3, 1);
feed(monitor, [10 10 10], 1);
codes = [11 10 10 11 9 9 10 11 7];
expectedEvents = [0 1 1 1 2 2 3 3 4];
for index = 1:numel(codes)
    assert(~monitor.update(codes(index), index + 3));
    assert(monitor.EventCount == expectedEvents(index));
end
% Covered above: departure and dwell do not count, a center touch counts,
% 11->9 is a strict crossing, and 11->7 crosses at the inclusive edge.
assert(~monitor.update(14, 13));           % outside [7, 13]
state = monitor.getState();
assert(state.ResetCount == 1 && state.EventCount == 0);
assert(isnan(state.CenterUnwrapped) && isempty(state.SearchCodes));
end

function testResetStartsFreshNextBlock()
monitor = loop_monitor(3, 2, 1, 1);
feed(monitor, [4 4 5 4], 1);
assert(monitor.CenterUnwrapped == 4);
assert(~monitor.update(3, 5));
assert(~monitor.update(6, 6));             % outlier is discarded
state = monitor.getState();
assert(state.ResetCount == 1 && state.ModeOccurrences == 0);
assert(isempty(state.SearchCodes) && isnan(state.CandidateStartBlock));

assert(~monitor.update(4, 7));
state = monitor.getState();
assert(isequal(state.SearchCodes, 4));
assert(isequal(state.SearchCounts, 1));    % neither old counts nor code 6 seeded
assert(~monitor.update(4, 8));
assert(~monitor.update(4, 9));
assert(monitor.CandidateStartBlock == 9);
end

function testPermanentFreeze()
monitor = loop_monitor(3, 1, 1, 1);
feed(monitor, [0 0 0 1], 1);
assert(monitor.update(0, 5));
before = monitor.getState();
assert(~monitor.update(1000, 6));
after = monitor.getState();
fields = {'Frozen', 'FreezeBlock', 'CenterUnwrapped', ...
    'CandidateStartBlock', 'ModeOccurrences', 'EventCount', 'ResetCount'};
for index = 1:numel(fields)
    assert(isequaln(before.(fields{index}), after.(fields{index})));
end
assert(after.LastBlock == 6 && after.ResetCount == 0);
end

function testCausalityAndIndependentInstances()
left = loop_monitor(3, 2, 1, 1);
right = loop_monitor(3, 2, 1, 1);
prefix = [4 4 4 5];
for block = 1:numel(prefix)
    assert(left.update(prefix(block), block) == ...
        right.update(prefix(block), block));
end
assert(isequaln(left.getState(), right.getState()));

assert(~left.update(4, 5));                % event one
assert(~left.update(5, 6));
assert(left.update(4, 7));                 % future A freezes
assert(~right.update(8, 5));               % future B resets instead
assert(~right.Frozen && right.ResetCount == 1);
assert(left.Frozen && left.ResetCount == 0);

untouched = loop_monitor(3, 1, 1, 1);
assert(isnan(untouched.LastBlock));         % distinct handle has no shared state
end

function testUnwrappedCodesRemainDistinct()
base = loop_monitor(3, 1, 1, 1);
shifted = loop_monitor(3, 1, 1, 1);
baseCodes = [-2 -2 -2 -1 -2];
for block = 1:numel(baseCodes)
    baseTrigger = base.update(baseCodes(block), block);
    shiftedTrigger = shifted.update(baseCodes(block) + 2048, block);
    assert(baseTrigger == shiftedTrigger);
end
assert(base.CenterUnwrapped == -2);
assert(shifted.CenterUnwrapped == 2046);
assert(base.EventCount == shifted.EventCount && shifted.Frozen);

noAlias = loop_monitor(2, 2, 200, 1);
assert(~noAlias.update(0, 1));
assert(~noAlias.update(128, 2));
state = noAlias.getState();
assert(isequal(state.SearchCodes, [0 128]));
assert(isequal(state.SearchCounts, [1 1]));
assert(state.SearchModeUnwrapped == 0);
assert(~noAlias.update(0, 3));
assert(noAlias.CenterUnwrapped == 0);       % 128 was not wrapped onto zero
end

function testInvalidInputs()
assertThrowsId(@() loop_monitor(0, 1, 0, 1), ...
    'loop_monitor:InvalidMinModeOccurrences');
assertThrowsId(@() loop_monitor(1, 1.5, 0, 1), ...
    'loop_monitor:InvalidMinEvents');
assertThrowsId(@() loop_monitor(1, 1, -1, 1), ...
    'loop_monitor:InvalidBandHalfWidth');
assertThrowsId(@() loop_monitor(1, 1, 0, Inf), ...
    'loop_monitor:InvalidStartBlock');
assertThrowsId(@() loop_monitor(1, 1, 0), ...
    'loop_monitor:InvalidConstructor');

monitor = loop_monitor(3, 2, 1, 1);
assertThrowsId(@() monitor.update(NaN, 1), ...
    'loop_monitor:InvalidCode');
assertThrowsId(@() monitor.update(0.5, 1), ...
    'loop_monitor:InvalidCode');
assertThrowsId(@() monitor.update(0, 0), ...
    'loop_monitor:InvalidBlock');
assert(~monitor.update(-128, 1));           % negative integer codes are valid
assertThrowsId(@() monitor.update(-128, 1), ...
    'loop_monitor:NonMonotonicBlock');
assertThrowsId(@() monitor.update(-128, 0.5), ...
    'loop_monitor:InvalidBlock');
assert(monitor.LastBlock == 1);             % rejected calls do not mutate state
end

function triggers = feed(monitor, codes, firstBlock)
triggers = false(size(codes));
for index = 1:numel(codes)
    triggers(index) = monitor.update(codes(index), firstBlock + index - 1);
end
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

monitor = loop_monitor(3, 2, 1, 1);
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
early = loop_monitor(3, 2, 1, 1);
early.enableSnrSettle(thresholdDb, 1, 50);
for block = 1:49
    assert(~early.updateSnrSettle(block, openEyeDb));
end
assert(early.SnrEwmaDb >= thresholdDb && ~early.SnrSettleDone);
assert(early.updateSnrSettle(50, openEyeDb));
assert(early.SnrSettleBlock == 50);
end

function testSnrSettleDisabledAndInvalidInputs()
% 未显式 enableSnrSettle 前必须拒绝调用；构造参数校验与既有检测器风格一致。
monitor = loop_monitor(3, 2, 1, 1);
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

% 两个检测器互不干扰。
assert(~monitor.updateFfeGate(7, 1));
assert(~monitor.SnrSettleDone);
assert(monitor.LastBlock == 1);
assert(~monitor.updateSnrSettle(1, 10));
assert(monitor.LastBlock == 1 && ~monitor.SnrSettleDone);
end

function testFrequencyStateLockStatic()
% 频偏跟踪的频率态平坦判据：尾窗均值恒定（前后半均值一致、std 小）且量级
% 匹配期望速率才算锁定。量级匹配对符号不敏感，避免采样/PD 极性约定影响判定。
window = 200;
expectedRate = -0.8192;

flat = expectedRate + 0.002 * sin((1:600) / 7);
[locked, diag] = loop_monitor.detectFrequencyStateLock(flat, window, ...
    expectedRate, 0.05, 0.05, 0.1);
assert(locked);
assert(abs(diag.MeanValue - expectedRate) < 0.05);
assert(diag.FlatnessOk && diag.RateOk);

% 仍在牵引（尾窗持续爬升）-> 未锁定（前后半均值差过大）。
ramp = linspace(-0.2, -0.8192, 600);
assert(~loop_monitor.detectFrequencyStateLock(ramp, window, expectedRate, ...
    0.05, 0.05, 0.1));

% 平坦但数值错误（仍在 0 附近）-> 平坦通过但量级不匹配 -> 未锁定。
wrong = 0.001 * cos((1:600) / 5);
[lockedWrong, diagWrong] = loop_monitor.detectFrequencyStateLock(wrong, ...
    window, expectedRate, 0.05, 0.05, 0.1);
assert(~lockedWrong && diagWrong.FlatnessOk && ~diagWrong.RateOk);

% 幅度匹配对符号不敏感：+0.8192 平坦也通过量级检查。
[lockedPos, diagPos] = loop_monitor.detectFrequencyStateLock(-flat, window, ...
    expectedRate, 0.05, 0.05, 0.1);
assert(lockedPos && diagPos.RateOk);

% 序列长度不足窗口 -> 未锁定。
assert(~loop_monitor.detectFrequencyStateLock(flat(1:100), window, ...
    expectedRate, 0.05, 0.05, 0.1));

% 期望速率关闭（NaN/Inf）只看平坦度。
assert(loop_monitor.detectFrequencyStateLock(wrong, window, NaN, ...
    0.05, 0.05, Inf));

assertThrowsId(@() loop_monitor.detectFrequencyStateLock([1 2 NaN], 2, ...
    0, 0.1, 0.1, 0.1), 'loop_monitor:InvalidFreqSeq');
assertThrowsId(@() loop_monitor.detectFrequencyStateLock([1 2 3], 0, ...
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
