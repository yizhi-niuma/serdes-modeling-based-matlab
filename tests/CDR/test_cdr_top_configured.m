function test_cdr_top_configured
% test_cdr_top_configured  Regression checks for the configured cdr_top DSP mode.
%
% 这些用例只驱动 code 域接口（centeredCode 进、采样相位出），不依赖任何
% waveform 缓存或 TI ADC，因此可在干净 MATLAB session 中独立运行。

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

testDefaultConfigAndConstruction();
testPipelineLatency();
testBoundaryValidMaskSkipsAdaptation();
testSlicePam4Encoding();
testDetectorAliasEquivalence();
testFreezeModeInhibitsWrite();
testPvtTrackKeepsWritingAndDropsStep();
testSnrSettleGateDownshift();
testResetStateRestoresInitialState();
testSaturatedIntegratorDoesNotLatchGate();
testStageOneDoesNotRaiseStepAfterStageTwo();
testInvalidConfigRejected();

fprintf('test_cdr_top_configured passed 12 / 12 checks.\n');
end

% ---------------------------------------------------------------- fixtures

function cfg = baseConfig()
% baseConfig  8-UI block、静止 dlev/FFE 的确定性配置。
cfg = cdr_top.defaultConfig();
cfg.BlockSize = 8;
cfg.Detector = 'mmpd';
cfg.TransitionFilter = false;   % 单测用全跳变，便于构造确定票型
cfg.VoterMode = 'mean';
cfg.VoterDenominator = 'auto';
cfg.Kp = 8;
cfg.Ki = 0;
cfg.MaxDeltaCode = 1;
cfg.PiInitialCode = 10;
cfg.DlevInnerInit = 1;
cfg.DlevOuterInit = 3;
cfg.DlevStepSize = 1e-12;
cfg.DlevStepSizeSettle = 1e-12;
cfg.FfeStepSize = 0;
cfg.FfeStepSizeSettle = 0;
cfg.FfeStepSizePvtTrack = 0;
cfg.FfeGateEnable = false;
end

function block = earlyBlock()
% earlyBlock  符号 [3 0 0 0 0 0 0 0]，errorBit 全 1，净票 +1/8。
block = [3.1, -2.9, -2.9, -2.9, -2.9, -2.9, -2.9, -2.9];
end

function block = lateBlock()
% lateBlock  符号 [0 3 3 3 3 3 3 3]，errorBit 全 1，净票 -1/8。
block = [-2.9, 3.1, 3.1, 3.1, 3.1, 3.1, 3.1, 3.1];
end

function outputs = driveAlternating(top, blockCount)
% driveAlternating  交替喂 early/late 块，收集所有有效输出。
outputs = {};
for k = 1:blockCount
    if mod(k, 2) == 1
        data = earlyBlock();
    else
        data = lateBlock();
    end
    out = top.processBlock(data);
    if out.HasOutput
        outputs{end + 1} = out; %#ok<AGROW>
    end
end
out = top.flush();
if out.HasOutput
    outputs{end + 1} = out;
end
end

% ------------------------------------------------------------------- tests

function testDefaultConfigAndConstruction()
cfg = cdr_top.defaultConfig();
assert(isstruct(cfg) && isscalar(cfg));
% defaultConfig 必须与生产 v3 当前默认一致，避免"默认值漂移"再次发生。
assert(cfg.BlockSize == 64 && cfg.SamplesPerSymbol == 128);
assert(strcmp(cfg.Detector, 'mmpd') && cfg.TransitionFilter);
assert(strcmp(cfg.VoterMode, 'mean') && strcmp(cfg.VoterDenominator, 'auto'));
assert(cfg.Kp == 8 && cfg.Ki == 0.03 && cfg.MaxDeltaCode == 1);
assert(cfg.DlevStepSize == 0.5 && cfg.DlevStepSizeSettle == 0.1);
assert(cfg.FfeStepSize == 0.004 && cfg.FfeStepSizeSettle == 2e-4);
assert(strcmp(cfg.FfeGateMode, 'pvt-track') && cfg.FfeStepSizePvtTrack == 2e-4);

top = cdr_top(baseConfig());
[code, slip] = top.getSamplingPhase();
assert(code == 10 && slip == 0);
state = top.getState();
assert(state.BlockIndex == 0 && state.SampleBlockCount == 0);
assert(~state.HavePending);
% config 模式下 getState 必须暴露全部有状态子模块。
for name = {'Dlev', 'Ffe', 'FfeLoop', 'Monitor'}
    assert(isfield(state, name{1}));
end
end

function testPipelineLatency()
% FFE 需要下一块的前光标样本，所以第 k 块的判决在第 k+1 次调用才生效：
% phase[k+1] == phase[k]，phase[k+2] == phase[k] + delta[k]。
top = cdr_top(baseConfig());
[code0, slip0] = top.getSamplingPhase();

first = top.processBlock(earlyBlock());
assert(~first.HasOutput, 'The first configured block must only fill the pipeline.');
[code1, slip1] = top.getSamplingPhase();
assert(code1 == code0 && slip1 == slip0, ...
    'The first block must not move the PI.');

second = top.processBlock(lateBlock());
assert(second.HasOutput);
assert(second.BlockIndex == 1, 'The first processed block index must be 1.');
assert(second.SampleCodeWrapped == code0 && second.SampleUiSlip == slip0, ...
    'Block 1 must report the phase snapshot taken when it was submitted.');
% 首个处理块缺过去样本，只有尾部 5 个有效样本且全为静止符号，净票为 0。
assert(numel(second.FfeOutput) == 5);
assert(second.PhaseError == 0 && second.DeltaCode == 0);
[code2, slip2] = top.getSamplingPhase();
assert(code2 == code0 && slip2 == slip0);
assert(second.NextCodeWrapped == code2);

% 第三次调用处理第 2 块（8 个有效样本）：只有一个 0->3 上升跳变，
% errorBit 全 1 => late，净票 -1/8；Kp=8 => deltaCode = -1。
third = top.processBlock(earlyBlock());
assert(third.BlockIndex == 2);
assert(all(third.ValidMask) && numel(third.FfeOutput) == 8);
assert(abs(third.PhaseError - (-1 / 8)) < 1e-12, ...
    'The mean voter must normalize the net vote by the valid sample count.');
assert(third.DeltaCode == -1);
% 环路亚码连续量：整数 PI code 藏住的相位速度需求，用于区分抖动与漂移。
% control = Kp*phaseError + FrequencyState，Ki=0 时积分态恒为 0。
assert(abs(third.LoopControl - 8 * (-1 / 8)) < 1e-12, ...
    'LoopControl must equal Kp*phaseError + FrequencyState.');
assert(third.LoopFrequencyState == 0, 'Ki=0 must leave the integral state at 0.');
assert(abs(third.LoopCodeResidue) < 1, 'CodeResidue must stay sub-code.');
assert(third.LoopPendingCode == 0, 'No slew backlog is expected here.');
[code3, slip3] = top.getSamplingPhase();
assert(code3 == code0 - 1 && slip3 == slip0, ...
    'delta[2] must only become visible for the fourth sampled block.');
assert(third.NextCodeWrapped == code3);
end

function testBoundaryValidMaskSkipsAdaptation()
cfg = baseConfig();
cfg.FfeStepSize = 0.01;
cfg.FfeStepSizeSettle = 0.01;
top = cdr_top(cfg);

top.processBlock(earlyBlock());
firstProcessed = top.processBlock(lateBlock());
% 首个处理块缺 PostTapCount 个过去样本，头 3 个输出无效。
assert(numel(firstProcessed.ValidMask) == 8);
assert(isequal(firstProcessed.ValidMask(1:3), [false false false]));
assert(all(firstProcessed.ValidMask(4:end)));
assert(numel(firstProcessed.FfeOutput) == 5);
assert(~firstProcessed.FfeAdaptationCalculated, ...
    'Short blocks must not run the FFE update.');
assert(~firstProcessed.FfeWriteApplied);
assert(all(isnan(firstProcessed.FfeRawDelta)));

interior = top.processBlock(earlyBlock());
assert(all(interior.ValidMask) && numel(interior.FfeOutput) == 8);
assert(interior.FfeAdaptationCalculated && interior.FfeWriteApplied);
assert(all(isfinite(interior.FfeRawDelta)));

dlevBefore = interior.DlevInner;
tail = top.flush();
% 末块缺 PreTapCount 个未来样本，尾 2 个输出无效。
assert(isequal(tail.ValidMask(end - 1:end), [false false]));
assert(numel(tail.FfeOutput) == 6);
assert(~tail.FfeAdaptationCalculated && ~tail.FfeWriteApplied);
assert(tail.DlevInner == dlevBefore, ...
    'Short blocks must not run the dLev update.');
assert(isequal(tail.FfeCoefficients, interior.FfeCoefficients));
% flush 之后 pending 已清空，再次 flush 只返回空输出。
again = top.flush();
assert(~again.HasOutput);
end

function testSlicePam4Encoding()
sample = [3.1, -2.9, 0.4, -0.4, 0];
[decision, sliceError, dataSymbol, errorBit] = ...
    cdr_top.slicePam4(sample, 1, 3, 2);
assert(isequal(decision, [3, -3, 1, -1, 1]));
assertClose(sliceError, sample - decision);
assert(isequal(dataSymbol, [3, 0, 2, 1, 2]));
assert(isequal(errorBit, [1, 1, 0, 1, 0]));
% 行/列输入都必须归一成行向量输出。
[decisionColumn, ~, symbolColumn] = cdr_top.slicePam4(sample(:), 1, 3, 2);
assert(isrow(decisionColumn) && isequal(decisionColumn, decision));
assert(isequal(symbolColumn, dataSymbol));
end

function testDetectorAliasEquivalence()
% ssmmpd 只是 mmpd 的别名：cdr_pd.mmpd 的入参本来只接受 0-3 符号与 0/1 误差位，
% 符号化已内蕴在接口里，因此两者必须逐块完全一致。
cfgMmpd = baseConfig();
cfgAlias = baseConfig();
cfgAlias.Detector = 'ssmmpd';
topMmpd = cdr_top(cfgMmpd);
topAlias = cdr_top(cfgAlias);

assert(strcmp(topAlias.getState().Detector, 'mmpd'), ...
    'The ssmmpd alias must normalize to mmpd.');

outMmpd = driveAlternating(topMmpd, 12);
outAlias = driveAlternating(topAlias, 12);
assert(numel(outMmpd) == numel(outAlias));
for k = 1:numel(outMmpd)
    assert(isequal(outMmpd{k}.PhaseDecision, outAlias{k}.PhaseDecision));
    assert(outMmpd{k}.PhaseError == outAlias{k}.PhaseError);
    assert(outMmpd{k}.DeltaCode == outAlias{k}.DeltaCode);
    assert(outMmpd{k}.UnwrappedCode == outAlias{k}.UnwrappedCode);
end
end

function testFreezeModeInhibitsWrite()
cfg = gateConfig('freeze');
top = cdr_top(cfg);
outputs = driveAlternating(top, 40);

frozenIndex = findFirstGateEngaged(outputs);
assert(~isempty(frozenIndex), 'The FFE gate never engaged in freeze mode.');
gatedCoefficients = outputs{frozenIndex}.FfeCoefficients;

sawCalculation = false;
for k = frozenIndex + 1:numel(outputs)
    out = outputs{k};
    assert(out.GateEngaged);
    assert(isequal(out.FfeCoefficients, gatedCoefficients), ...
        'Frozen coefficients must stay constant after the gate engages.');
    assert(~out.FfeWriteApplied, 'Freeze mode must inhibit coefficient writes.');
    assert(all(out.FfeAppliedDelta == 0));
    if out.FfeAdaptationCalculated
        sawCalculation = true;
        assert(all(isfinite(out.FfeRawDelta)));
        assert(all(isfinite(out.FfeProposedCoefficients)));
    end
end
assert(sawCalculation, ...
    'Freeze mode must keep computing raw SS-LMS deltas after freezing.');

state = top.getState();
assert(state.Monitor.FreqGateDone);
assert(isequal(state.GatedCoefficients, gatedCoefficients));
% freeze 模式不得改动 FFE 步长。
assert(state.FfeLoop.StepSize == cfg.FfeStepSize);
end

function testPvtTrackKeepsWritingAndDropsStep()
cfg = gateConfig('pvt-track');
top = cdr_top(cfg);
outputs = driveAlternating(top, 40);

engagedIndex = findFirstGateEngaged(outputs);
assert(~isempty(engagedIndex), 'The FFE gate never engaged in pvt-track mode.');
state = top.getState();
assert(state.Monitor.FreqGateDone);
% pvt-track 不停写，只把带宽收窄到 FfeStepSizePvtTrack。
assert(state.FfeLoop.StepSize == cfg.FfeStepSizePvtTrack);

sawWrite = false;
for k = engagedIndex + 1:numel(outputs)
    out = outputs{k};
    assert(out.GateEngaged);
    if out.FfeAdaptationCalculated
        assert(out.FfeWriteApplied, ...
            'pvt-track mode must keep applying coefficient deltas.');
        sawWrite = true;
    end
end
assert(sawWrite, 'pvt-track mode produced no post-engage write.');
end

function testSaturatedIntegratorDoesNotLatchGate()
% 钳在 ±FrequencyLimit 上的积分频率态是"完美平坦"的(半差=0、std=0)，在库默认
% 的纯平坦口径(FfeGateFreqExpectedRate=NaN / FfeGateFreqRateTol=Inf)下会被
% detectFrequencyStateLock 判成锁定。那是 railed 而不是锁定：眼睛通常还没开、
% 环路根本没在跟踪，若让它闩锁 stage-2 就会把 dLev/FFE 过早降到 PVT 档。
cfg = gateConfig('pvt-track');
cfg.Ki = 0.5;                 % 让积分器真的累积
cfg.FrequencyLimit = 0.01;    % 一次单向脉冲就撞上限幅
cfg.FfeGateFreqWindowBlocks = 6;
top = cdr_top(cfg);

% 先用一次单向脉冲(1 个 late 后接恒定 early)把积分器踢到限幅；此后
% phaseError 恒为 0，积分器就停在钳位值上 => 尾窗"钳位且完全平坦"，
% 正是会骗过纯平坦口径的形态。
outputs = {};
drive = [{lateBlock()}, repmat({earlyBlock()}, 1, 30)];
for k = 1:numel(drive)
    out = top.processBlock(drive{k});
    if out.HasOutput
        outputs{end + 1} = out; %#ok<AGROW>
    end
end

state = top.getState();
% 前提 1：积分器确实饱和了，否则本用例什么都没验证到。
assert(abs(state.LoopFilter.FrequencyState) >= ...
    cfg.FfeGateFreqSatFrac * cfg.FrequencyLimit, ...
    'Test premise failed: the integrator did not saturate.');
% 前提 2：尾窗确实完全平坦，且该判据本身会接受它——这才证明本用例真的能
% 捕获"饱和被误判为锁定"，而不是因为别的原因没闩锁。
tail = cellfun(@(o) o.LoopFrequencyState, outputs(end - 5:end));
assert(std(tail) == 0, 'Test premise failed: the railed tail is not flat.');
assert(loop_monitor.detectFrequencyStateLock(tail, numel(tail), ...
    cfg.FfeGateFreqExpectedRate, cfg.FfeGateFreqMeanHalfDiffTol, ...
    cfg.FfeGateFreqStdTol, cfg.FfeGateFreqRateTol), ...
    'Test premise failed: the criterion should accept this railed tail.');
% 断言：cdr_top 必须把这种块挡在门控窗口之外。
assert(~state.Monitor.FreqGateDone, ...
    'A railed (saturated) integrator must not latch the freq-state gate.');
assert(isempty(findFirstGateEngaged(outputs)), ...
    'No block may report a gate event while the integrator is railed.');
assert(state.FfeLoop.StepSize ~= cfg.FfeStepSizePvtTrack, ...
    'A railed integrator must not trigger the stage-2 mu downshift.');
end

function testStageOneDoesNotRaiseStepAfterStageTwo()
% 两级降档都是一次性闩锁，且 stage-1 在 processConfiguredBlock 里先执行。若
% stage-2 曾在更早的块先触发，后到的 stage-1 不得把已经降到 PVT 档的步长抬回
% settle 档（0.02 -> 0.1 会让步长调度反向）。
cfg = gateConfig('pvt-track');
cfg.DlevStepSize = 0.5;
cfg.DlevStepSizeSettle = 0.1;
cfg.DlevStepSizePvtTrack = 0.02;
% baseConfig 的 Ki=0 => 频率态恒 0，是合法的"平坦且未饱和"，门控在窗口填满后
% 立刻闩锁；把 SNR 换挡的 minBlock 推后，强制 stage-2 先于 stage-1 触发。
cfg.FfeGateFreqWindowBlocks = 4;
cfg.SnrSettleThresholdDb = -100;   % 任何有限 SNR 都能过
cfg.SnrSettleMinBlock = 20;
top = cdr_top(cfg);

outputs = driveAlternating(top, 40);
assert(~isempty(outputs));
state = top.getState();
assert(state.Monitor.FreqGateDone, 'stage-2 should have latched.');
assert(state.Monitor.SnrSettleDone, 'stage-1 should have fired later.');
assert(state.Monitor.FreqGateBlock < state.Monitor.SnrSettleBlock, ...
    'Test premise failed: stage-2 must latch before stage-1 fires.');
% 关键断言：晚到的 stage-1 不得抬回步长。
assert(state.Dlev.StepSize == cfg.DlevStepSizePvtTrack, ...
    'A late stage-1 must not raise the dLev step back to the settle tier.');
assert(state.FfeLoop.StepSize == cfg.FfeStepSizePvtTrack, ...
    'A late stage-1 must not raise the FFE step back to the settle tier.');
end

function testSnrSettleGateDownshift()
% 眼质量门控换挡在 cdr_top 侧的接线与动作施加。
% 判据本身(平滑、一次性、闭眼瞬态不误触、minBlock 压制)在 test_loop_monitor
% 覆盖；这里只验证 cdr_top 会算 FOM、会消费触发、并把两个环路的步长都降下来。
cfg = baseConfig();
% 阈值取极低 + alpha=1 让触发在本夹具上确定化，不依赖具体 SNR 数值。
cfg.SnrSettleThresholdDb = -100;
cfg.SnrSettleAlpha = 1;
cfg.SnrSettleMinBlock = 3;
cfg.DlevStepSize = 0.5;
cfg.DlevStepSizeSettle = 0.1;
cfg.FfeStepSize = 0.01;
cfg.FfeStepSizeSettle = 0.001;
top = cdr_top(cfg);
outputs = driveAlternating(top, 14);

blockIndex = cellfun(@(out) out.BlockIndex, outputs);
snrDone = cellfun(@(out) out.SnrSettleDone, outputs);
dlevMu = cellfun(@(out) out.DlevStepSize, outputs);
ffeMu = cellfun(@(out) out.FfeStepSize, outputs);

firstDone = find(snrDone, 1);
assert(~isempty(firstDone), 'The SNR-gated mu downshift never fired.');
assert(blockIndex(firstDone) >= cfg.SnrSettleMinBlock, ...
    'The trigger must be suppressed below SnrSettleMinBlock.');
assert(all(snrDone(firstDone:end)), 'SnrSettleDone must latch.');
assert(all(dlevMu(1:firstDone - 1) == cfg.DlevStepSize), ...
    'dLev must stay at capture mu before the trigger.');
assert(all(ffeMu(1:firstDone - 1) == cfg.FfeStepSize), ...
    'FFE must stay at capture mu before the trigger.');
assert(dlevMu(firstDone) == cfg.DlevStepSizeSettle, ...
    'Stage 1 must drop the dLev step, not only the FFE step.');
assert(ffeMu(firstDone) == cfg.FfeStepSizeSettle);

state = top.getState();
assert(state.Monitor.SnrSettleEnabled);
assert(state.Monitor.SnrSettleBlock == blockIndex(firstDone));
assert(state.FfeLoop.StepSize == cfg.FfeStepSizeSettle);
assert(state.Dlev.StepSize == cfg.DlevStepSizeSettle);
end

function testResetStateRestoresInitialState()
cfg = gateConfig('pvt-track');
top = cdr_top(cfg);
driveAlternating(top, 40);
dirty = top.getState();
assert(dirty.Monitor.FreqGateDone && dirty.BlockIndex > 0);

top.resetState();
clean = top.getState();
assert(clean.BlockIndex == 0 && clean.SampleBlockCount == 0);
assert(~clean.HavePending && ~clean.PendingHasPast);
assert(isempty(clean.PreviousDataSymbol) && isempty(clean.PreviousErrorBit));
% 门控与换挡的判决状态都归 loop_monitor 所有，cdr_top 不再自留副本。
assert(~clean.Monitor.SnrSettleDone && isnan(clean.Monitor.SnrSettleBlock));
assert(clean.Monitor.SnrSettleEnabled);
assert(all(isnan(clean.GatedCoefficients)));
assert(~clean.Monitor.FreqGateDone && ~clean.Monitor.Frozen && ...
    clean.Monitor.EventCount == 0);
assert(isequal(clean.Ffe.Coefficients, cfg.FfeInitCoefficients));
assert(clean.Dlev.DLevInner == cfg.DlevInnerInit);
assert(clean.Dlev.DLevOuter == cfg.DlevOuterInit);
assert(clean.Dlev.StepSize == cfg.DlevStepSize);
assert(clean.FfeLoop.StepSize == cfg.FfeStepSize);
assert(clean.PhaseInterpolator.CodeWrapped == cfg.PiInitialCode);
assert(clean.PhaseInterpolator.UiSlip == 0);
assert(clean.LoopFilter.FrequencyState == 0);
% 复位后重跑必须与首跑逐块一致。
firstRun = driveAlternating(cdr_top(gateConfig('pvt-track')), 20);
top.resetState();
secondRun = driveAlternating(top, 20);
assert(numel(firstRun) == numel(secondRun));
for k = 1:numel(firstRun)
    assert(firstRun{k}.UnwrappedCode == secondRun{k}.UnwrappedCode);
    assert(isequal(firstRun{k}.FfeCoefficients, secondRun{k}.FfeCoefficients));
end
end

function testInvalidConfigRejected()
cfg = baseConfig();
missing = rmfield(cfg, 'Kp');
assertThrowsId(@() cdr_top(missing), 'cdr_top:InvalidKp');

assertThrowsId(@() cdr_top(setField(cfg, 'Detector', 'mmpd2')), ...
    'cdr_top:InvalidDetector');
assertThrowsId(@() cdr_top(setField(cfg, 'VoterMode', 'median')), ...
    'cdr_top:InvalidVoterMode');
assertThrowsId(@() cdr_top(setField(cfg, 'FfeGateMode', 'hold')), ...
    'cdr_top:InvalidFfeGateMode');
assertThrowsId(@() cdr_top(setField(cfg, 'DlevOuterInit', 1)), ...
    'cdr_top:InvalidDlevOuterInit');
assertThrowsId(@() cdr_top(setField(cfg, 'DlevStepSize', 0)), ...
    'cdr_top:InvalidDlevStepSize');
assertThrowsId(@() cdr_top(setField(cfg, 'FfeStepSize', -1)), ...
    'cdr_top:InvalidFfeStepSize');
assertThrowsId(@() cdr_top(setField(cfg, 'PiInitialCode', 2 ^ cfg.PiNumBit)), ...
    'cdr_top:InvalidPiInitialCode');
assertThrowsId(@() cdr_top(setField(cfg, 'FfeInitCoefficients', ...
    [0 0 2 0 0 0])), 'cdr_top:InvalidFfeInitCoefficients');
% TransitionFilter 现在是三模式枚举 0/1/2 (全跳变 / 对称 / 仅外层 ±3)，并保留
% logical 向后兼容。非法的是枚举外的值与非标量。
assertThrowsId(@() cdr_top(setField(cfg, 'TransitionFilter', 3)), ...
    'cdr_top:InvalidTransitionFilter');
assertThrowsId(@() cdr_top(setField(cfg, 'TransitionFilter', -1)), ...
    'cdr_top:InvalidTransitionFilter');
assertThrowsId(@() cdr_top(setField(cfg, 'TransitionFilter', [0 1])), ...
    'cdr_top:InvalidTransitionFilter');
for mode = {0, 1, 2, true, false}
    accepted = cdr_top(setField(cfg, 'TransitionFilter', mode{1}));
    acceptedState = accepted.getState();
    assert(acceptedState.TransitionFilter == double(mode{1}), ...
        'TransitionFilter must be normalized to a double mode index.');
end

top = cdr_top(cfg);
assertThrowsId(@() top.processBlock(ones(1, cfg.BlockSize + 1)), ...
    'cdr_top:InvalidCenteredCode');
assertThrowsId(@() top.processBlock(ones(cfg.BlockSize, 1)), ...
    'cdr_top:InvalidCenteredCode');
end

% ----------------------------------------------------------------- helpers

function cfg = gateConfig(mode)
cfg = baseConfig();
cfg.FfeStepSize = 0.01;
cfg.FfeStepSizeSettle = 0.01;
cfg.FfeStepSizePvtTrack = 1e-4;
cfg.FfeGateEnable = true;
cfg.FfeGateMode = mode;
cfg.FfeGateMinModeOccurrences = 3;
cfg.FfeGateMinEvents = 2;
cfg.FfeGateBandHalfWidth = 3;
cfg.FfeGateStartBlock = 1;
% cdr_top 的唯一门控判据是 freq-state。这里只验证 freeze/pvt-track 机制
% (门控闩锁后的写抑制与步长动作)，不验证判据的辨别力(那是
% test_freq_state_gate / test_loop_monitor 的职责)，所以用一个小窗口、
% 极松容差、仅判平坦性(期望速率 NaN)的门控，保证在这段短驱动内触发。
cfg.FfeGateFreqWindowBlocks = 6;
cfg.FfeGateFreqExpectedRate = NaN;
cfg.FfeGateFreqMeanHalfDiffTol = 100;
cfg.FfeGateFreqStdTol = 100;
cfg.FfeGateFreqRateTol = Inf;
cfg.FfeGateFreqMinBlock = 1;
end

function index = findFirstGateEngaged(outputs)
index = [];
for k = 1:numel(outputs)
    if outputs{k}.LoopLockedEvent
        index = k;
        return;
    end
end
end

function cfg = setField(cfg, name, value)
cfg.(name) = value;
end

function assertClose(actual, expected)
assert(isequal(size(actual), size(expected)));
assert(max(abs(actual(:) - expected(:))) < 1e-12);
end

function assertThrowsId(fcn, expectedId)
threw = false;
try
    fcn();
catch err
    threw = true;
    assert(strcmp(err.identifier, expectedId), ...
        'Expected %s but got %s.', expectedId, err.identifier);
end
assert(threw, 'Expected %s but no error was thrown.', expectedId);
end
