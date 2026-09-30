function result = cdr_three_loop_ppm(varargin)
%CDR_THREE_LOOP_PPM 频偏条件下的 CDR+dlev+CDR-FFE 三环捕获。
%   RESULT = CDR_THREE_LOOP_PPM(...) 与 cdr_dlev_cdrffe_sslms_v4 完全一样地
%   驱动已配置的码域 cdr_top 内核，但在调用方自己拥有的波形地址线上注入一个
%   接收端采样时钟频偏（ppm）。DSP 内核对频偏无感知：频偏表现为一个缓慢的、
%   按块累积的整数漂移，加在 ADC 块起始索引上，三个环路必须靠自己跟上它。
%   换句话说，频偏只改采样地址，不改内核的任何一行算法。
%
%
%   频偏注入模型（方案 A，RX 时钟模型）：
%     - 缓存的 TX 波形从不重采样；一个数据符号恒定占据 SamplesPerSymbol
%       （=128）个缓存样本。
%     - 符号约定：+FreqOffsetPpm 让一个 RX UI 跨越
%       SamplesPerSymbol*(1+delta) 个缓存样本，delta = ppm*1e-6，即
%       T_RX = T_TX*(1+delta)：RX 时钟比 TX 符号率更慢
%       （TX 数据跑在 RX 时钟前面）。环路通过推迟 PI code 来把眼睛拉住，
%       所以正 ppm 对应的 FrequencyState 是负的。
%       由于 128*(1+delta) 不是整数，
%       精确的累积漂移用浮点保存，只在形成块起始地址时才向 128 倍采样
%       栅格取整一次。对累积值取整（而绝不是对每块增量取整）能把量化
%       误差限制在 +/-0.5 个样本 = +/-1/128 UI，与 PI 分辨率同量级。
%       在一个 64-UI 的 ADC 块内，64 个样本仍然按 128 的间隔取
%       （块内漂移 <= |delta|*128*64 <= 0.82 个样本，未建模）；
%       详见 docs/MODEL_ASSUMPTIONS.md。
%
%
%   锁定判据（对任意频偏都以频率态为主）：
%     - loop_monitor.detectFrequencyStateLock —— 环路积分器的频率态在尾窗内
%       均值恒定，且与期望漂移率相符（0 ppm 时为 0）。这一条单独决定判决，
%       并由 slew 饱和守卫否决。
%     - FreqOffsetPpm ~= 0 时额外要求
%       loop_monitor.detectRotationPeriodLock —— PI code 的旋转周期
%       （每个 UI slip 所需块数）恒定 —— 仅当旋转周期能塞进锁定窗口时才适用
%       （RotationCriterionApplicable）。0 ppm 下没有旋转，
%       所以只有频率态判据生效。
%     本套件此前在 0 ppm 下使用的众数 center-touch 判据
%     （detect_pi_center_touch_lock）已于 2026-09-26 退役：已经证明 0 ppm 下
%     频率态判决与它 32/32 一致。该 helper 本身仍保留给 v3/v4 套件，
%     那两个套件还在用它。
%
%   需求诊断量（不参与判决通过/失败）：“PI 实际 code 减去 PI 理想频偏补偿
%   code”这条轨迹。理想补偿 PI code 会把眼相位保持恒定，因此一旦跟上，
%   残差就是平的；还在捕获过程中时，残差呈斜坡上升。
%

thisFile = mfilename('fullpath');
testDir = fileparts(fileparts(fileparts(thisFile)));
addpath(testDir);
paths = setup_cdr_three_loop_wi_ppm_v1_paths();
cdrValidationDir = paths.CdrValidationDir;
options = parseLoopOptions(varargin{:});
validateOptions(options);

cachePath = fullfile(cdrValidationDir, 'test_cdr', 'result', ...
    options.CosimDir, 'channel_ctle.mat');
assert(isfile(cachePath), ...
    'Run test_channel_ctle_cosim first to generate channel_ctle.mat.');
cacheFile = matfile(cachePath);
samplePerSymbol = double(cacheFile.samplePerSymbol);
numCachedSymbols = double(cacheFile.numSymbols);
assert(samplePerSymbol == 128, ...
    'The cached CTLE waveform must use 128 samples/UI.');
assert(logical(getCachePeriodFlag(cacheFile)), ...
    'The cached CTLE waveform must contain a complete PRBS period.');

adcBlockUi = 64;
% 整次运行的频偏漂移预算（UI）。前侧余量（baseUi）与后侧余量（uiGuard）
% 共同吸收 ppm 漂移加上环路自身的捕获期 UI slip，
% 从而保证采样窗口永远不会越出缓存。
driftBudgetUi = ceil(abs(options.FreqOffsetPpm) * 1e-6 * ...
    options.NumBlock * adcBlockUi);

analysisStartUi = 512;
analysisNumUi = options.AnalysisNumUi;
assert(mod(analysisNumUi, adcBlockUi) == 0, ...
    'The fixed analysis segment must contain complete 64-UI blocks.');
assert(analysisStartUi + analysisNumUi <= numCachedSymbols, ...
    'The fixed analysis segment exceeds the CTLE cache.');
segmentFirstSample = analysisStartUi * samplePerSymbol + 1;
segmentLastSample = (analysisStartUi + analysisNumUi) * samplePerSymbol;
ctleSegment = double(cacheFile.ctleOutput( ...
    1, segmentFirstSample:segmentLastSample));
assert(numel(ctleSegment) == analysisNumUi * samplePerSymbol, ...
    'The loaded CTLE analysis segment has the wrong length.');

adcLaneCount = 64;
adcSarPerTah = 8;
adcResolutionBits = 7;
adcFullRange = 4;
adcZeroCode = 2^(adcResolutionBits - 1);
referencePhase = 19;
cdrFfeTapOffset = -2:3;
cdrFfePreTapCount = 2;
cdrFfeTapCount = numel(cdrFfeTapOffset);
cdrFfeMainTapIndex = cdrFfePreTapCount + 1;
cdrFfeEvalOffset = -3:6;
[laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol);

% 离线响应只负责初始化选项、真值统计与绘图。
channelCtleImpulse = double(cacheFile.channelCtleImpulse);
channelCtleSymbolPulse = conv(channelCtleImpulse(:), ...
    ones(samplePerSymbol, 1));
channelAdcCursorOffset = ...
    (cdrFfeEvalOffset(1) - cdrFfeTapOffset(end)): ...
    (cdrFfeEvalOffset(end) - cdrFfeTapOffset(1));
analogCursor = samplePulseAtPhase(channelCtleSymbolPulse, ...
    samplePerSymbol, referencePhase, channelAdcCursorOffset);
adcCursorCode = quantizeSamplesWithTiAdc(analogCursor, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    samplePerSymbol, laneToTimeOrder, nominalBlockLength);
adcCursorCodeCentered = adcCursorCode - adcZeroCode;
[cdrFfeCoefficients, cdrFfeDesign] = optimizeCdrFfe( ...
    adcCursorCodeCentered, channelAdcCursorOffset, ...
    cdrFfeTapOffset, cdrFfeEvalOffset);

referenceOutput = processOnePhase(ctleSegment, referencePhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, ...
    adcFullRange, adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, adcBlockUi);
levelCenter = estimatePam4Centers(referenceOutput);
dlevInnerReference = (abs(levelCenter(2)) + abs(levelCenter(3))) / 2;
dlevOuterReference = (abs(levelCenter(1)) + abs(levelCenter(4))) / 2;

switch lower(char(options.FfeInitMode))
    case 'plana'
        ffeBiasVector = zeros(1, cdrFfeTapCount);
        freeTapMask = true(1, cdrFfeTapCount);
        freeTapMask(cdrFfeMainTapIndex) = false;
        ffeBiasVector(freeTapMask) = options.FfeBiasScale;
        ffeInitCoefficients = cdrFfeCoefficients + ffeBiasVector;
    case 'planb'
        ffeInitCoefficients = zeros(1, cdrFfeTapCount);
        ffeInitCoefficients(cdrFfeMainTapIndex) = 1;
    otherwise
        error('cdr_three_loop_ppm:InvalidFfeInitMode', ...
            'FfeInitMode must be ''planA'' or ''planB''.');
end

baseUi = 256 + driftBudgetUi;
uiGuard = 192 + driftBudgetUi;
maxFirstUi = analysisNumUi - adcBlockUi - uiGuard;
numBlocks = floor((maxFirstUi - baseUi) / adcBlockUi);
assert(numBlocks > 60, 'The analysis segment is too short for the loop run.');
if isempty(options.StartPhaseList)
    startPhaseList = 0:options.StartPhaseStep:samplePerSymbol - 1;
else
    startPhaseList = double(options.StartPhaseList(:).');
end
numStartPhase = numel(startPhaseList);

% 频偏符号约定（用户 2026-09-24 确认）：
%   +FreqOffsetPpm 为正时，使缓存波形读指针每 UI 额外前进一段 ppm
%   比例的量，即一个 RX UI 对应 SamplesPerSymbol*(1+delta) 个缓存
%   采样点。在一个 block 内，RX 前进 64 个 RX UI，而地址
%   前进 64*128 + drift 个采样点，因此
%     64*T_RX = (8192 + drift)*T_TX/128  =>  T_RX = T_TX*(1 + drift/8192),
%   由此 T_RX = T_TX*(1+delta)：RX 采样时钟比 TX
%   符号速率慢 ppm，等价于 TX 数据领先于 RX 时钟。
%   环路通过推迟 PI 码（码值越大相位越迟）来保持眼图，
%   因此稳态 FrequencyState 在正 ppm 时为负。
% 单位：PI code per block（1 code = 7 位 PI、128 samples/UI 下的 1 个采样点）。
driftRatePerBlockCode = options.FreqOffsetPpm * 1e-6 * ...
    samplePerSymbol * adcBlockUi;
isZeroPpm = options.FreqOffsetPpm == 0;
expectedFreqState = -driftRatePerBlockCode;
% PI 非理想性。'ab_constant' 为 cdr_pi 的物理 a+b=1 / atan2 模型；在
% 7 位 PI、128 samples/UI 下其 INL 为 2.891 LSB pk-pk（1 LSB = 1 code =
% 1 个波形采样点），整数缓存寻址将其量化为三个
% 不同的采样偏移。'ideal' 恢复完全线性的查表，此时
% 相位表查询退化为原始 code，运行结果
% 与非理想性引入前逐位一致。
piNonideal = lower(char(options.PiNonideal));
if ~ismember(piNonideal, {'ideal', 'ab_constant'})
    error('cdr_three_loop_ppm:InvalidPiNonideal', ...
        'PiNonideal must be ''ideal'' or ''ab_constant''; got ''%s''.', ...
        piNonideal);
end
% 在传给 cdr_top 之前先确定第二阶段的 gate 判据，因为 cdr_top
% 只接受具体名称。
% 第二阶段（settle -> PVT-track）降档由 frequency-state 锁定
% 来 gate，对每个频偏（含 0 ppm）均适用。已于 2026-09-26 验证：0 ppm 时
% freq-state gate 触发 32/32 次（已废弃的 center-touch gate 仅触发 29/32 次），
% 且 freq-state 判定结果与已废弃的 center-touch 判定结果 32/32 一致。
% center-touch 在本测试集中已不再使用；cdr_top 仍为 v3/v4 的
% FFE-freeze 路径保留该机制，二者是不同的机制。
ffeGateCriterion = 'freq-state';
if isZeroPpm
    expectedRotationPeriod = NaN;
else
    expectedRotationPeriod = samplePerSymbol / abs(driftRatePerBlockCode);
end
% 旋转周期的相对容差（对应绝对 block 数），参见 RotPeriodTolFrac。
if isempty(options.RotPeriodTol)
    if isZeroPpm
        rotPeriodTolBlocks = Inf;
    else
        rotPeriodTolBlocks = max(2, ...
            options.RotPeriodTolFrac * expectedRotationPeriod);
    end
else
    rotPeriodTolBlocks = options.RotPeriodTol;
end
% slew 利用率：环路必须提供的稳态速率除以每块 PI 增量上限。
% >= 1 意味着在当前 MaxDeltaCode 下该频偏物理上不可跟踪，
% 与捕获过程无关。
slewUtilization = abs(expectedFreqState) / options.MaxDeltaCode;
% 一个完全 slew 饱和的环路会呈现的旋转周期（MaxDeltaCode = 1 时为 128 块）；
% 仅作为上报的饱和特征，不参与判决。
saturatedRotationPeriod = samplePerSymbol / options.MaxDeltaCode;
if slewUtilization >= 1
    warning('cdr_three_loop_ppm:SlewLimitExceeded', ...
        ['Required %.4f code/block exceeds MaxDeltaCode = %g (slew ' ...
        'utilization %.3f): %+g ppm is not trackable regardless of ' ...
        'acquisition.'], abs(expectedFreqState), options.MaxDeltaCode, ...
        slewUtilization, options.FreqOffsetPpm);
end
phaseCodeTrace = zeros(numStartPhase, numBlocks);
uiSlipTrace = zeros(numStartPhase, numBlocks);
timingErrorTrace = zeros(numStartPhase, numBlocks);
deltaCodeTrace = zeros(numStartPhase, numBlocks);
loopControlTrace = zeros(numStartPhase, numBlocks);
loopFrequencyTrace = zeros(numStartPhase, numBlocks);
% 每个起始相位实际触发第二级（settle -> PVT-track）门控的块号；
% 整次运行都没触发则为 NaN。
stage2GateBlock = nan(1, numStartPhase);
% 第一级（capture -> settle）SNR 降档触发的块号；
% 若整次运行眼 SNR 从未越过阈值则为 NaN。
stage1SettleBlock = nan(1, numStartPhase);
loopCodeResidueTrace = zeros(numStartPhase, numBlocks);
loopPendingCodeTrace = zeros(numStartPhase, numBlocks);
unwrappedPhaseTrace = zeros(numStartPhase, numBlocks);
edgeCountTrace = zeros(numStartPhase, numBlocks);
dlevInnerTrace = zeros(numStartPhase, numBlocks);
dlevOuterTrace = zeros(numStartPhase, numBlocks);
dlevThresholdTrace = zeros(numStartPhase, numBlocks);
% 逐块的判决导向眼质量 FOM，10*log10(mean(d^2)/mean(e^2))。
% 仅作诊断：环路目前不消费它。它的存在是为了检验单一 dB 阈值能否把
% “眼闭”（此时 FFE 必须保持捕获期步长）与“眼开”（此时 mu 降档是安全的）
% 区分开。
snrDbTrace = nan(numStartPhase, numBlocks);
ffeCoeffTrace = zeros(numStartPhase, numBlocks, cdrFfeTapCount);
driftSampleTrace = zeros(numStartPhase, numBlocks);
lockedPhaseCode = nan(1, numStartPhase);
lockedFlag = false(1, numStartPhase);
freqLockFlag = false(1, numStartPhase);
rotationLockFlag = false(1, numStartPhase);
freqDiagList = cell(1, numStartPhase);
rotationDiagList = cell(1, numStartPhase);
piCenterDiagnostics = cell(1, numStartPhase);
phaseSettleStd = nan(1, numStartPhase);
slewSaturatedFlag = false(1, numStartPhase);
slewDeltaMeanAbs = nan(1, numStartPhase);
slewPendingMeanAbs = nan(1, numStartPhase);

[~, histogramPhaseIndex] = min(abs(startPhaseList - referencePhase));
histogramTargetSamples = 2048;
histogramOutputHistory = [];
settleBlocks = 30;
piLockWindowBlocks = min(options.LockWindowBlocks, numBlocks);
% 旋转周期判据要求尾窗内有足够多的完整 PI 旋转，才能形成 RotMinIntervals
% 个 slip 间隔。小频偏时一次旋转需要 128/|driftRate| 块，可能超过窗口长度，
% 此时该判据判为“不适用”（而不是“未通过”），
% 锁定判决回退为只用频率态判据。
% 这一条修好了此前小 ppm 被误报为 0/8 的缺陷。
if isZeroPpm
    rotationApplicable = false;
else
    rotationApplicable = (piLockWindowBlocks / expectedRotationPeriod) >= ...
        (options.RotMinIntervals + 1);
end
piLockMinEvents = 51;
piLockBandHalfWidth = 3;
captureBandHalfWidth = 6;
dlevSettleStdTolerance = 1.0;
ffeSettleStdTolerance = 0.01;

for startIndex = 1:numStartPhase
    startPhase = startPhaseList(startIndex);
    cfg = cdr_top.defaultConfig();
    cfg.BlockSize = adcBlockUi;
    cfg.SamplesPerSymbol = samplePerSymbol;
    cfg.Detector = 'mmpd';
    cfg.TransitionFilter = double(options.TransitionFilter);
    cfg.PdPolarity = options.Polarity;
    cfg.VoterMode = 'mean';
    cfg.VoterDenominator = 'auto';
    cfg.Kp = options.Kp;
    cfg.Ki = options.Ki;
    cfg.FrequencyLimit = options.FrequencyLimit;
    cfg.MaxDeltaCode = options.MaxDeltaCode;
    cfg.PiNumBit = 7;
    cfg.PiNonideal = piNonideal;
    cfg.PiInitialCode = startPhase;
    cfg.DlevInnerInit = options.DlevInnerInit;
    cfg.DlevOuterInit = options.DlevOuterInit;
    cfg.DlevPolarity = options.DlevPolarity;
    cfg.DlevStepSize = options.StepSize;
    cfg.DlevStepSizeSettle = options.StepSizeSettle;
    cfg.DlevStepSizePvtTrack = options.DlevStepSizePvtTrack;
    cfg.SnrSettleThresholdDb = options.SnrSettleThresholdDb;
    cfg.SnrSettleAlpha = options.SnrSettleAlpha;
    cfg.SnrSettleMinBlock = options.SnrSettleMinBlock;
    cfg.FfeInitCoefficients = ffeInitCoefficients;
    cfg.FfePreTapCount = cdrFfePreTapCount;
    cfg.FfeStepSize = options.FfeStepSize;
    cfg.FfeStepSizeSettle = options.FfeStepSizeSettle;
    cfg.FfeAdaptEnableMask = options.FfeAdaptEnableMask;
    cfg.FfeGateEnable = logical(options.FfeFreezeEnable);
    cfg.FfeGateMode = lower(char(options.FfeFreezeMode));
    cfg.FfeStepSizePvtTrack = options.FfeStepSizePvtTrack;
    cfg.FfeGateMinModeOccurrences = options.FfeFreezeMinModeOccurrences;
    cfg.FfeGateMinEvents = options.FfeFreezeMinEvents;
    cfg.FfeGateBandHalfWidth = options.FfeFreezeBandHalfWidth;
    cfg.FfeGateStartBlock = 1;
    % 第二级（settle -> PVT-track）降档门控。'center-touch' 是码域众数测试，
    % 只有当 PI code 停留在某一个码上时才可能触发，也就是只在零频偏下有效。
    % 'freq-state' 改用环路积分器频率态的平坦性判据，它就是离线判决所用的
    % 同一个 loop_monitor.detectFrequencyStateLock 的在线形式，
    % 因此在任意 ppm 下都仍然有意义。窗口与各项容差刻意取成与判决完全相同，
    % 这样门控触发的依据就是这次运行被评判的那条判据本身，
    % 而不是另一条独立调过参的规则。
    % 两者同源是在线门控与离线判据逐块对齐的前提。
    %
    cfg.FfeGateCriterion = ffeGateCriterion;
    cfg.FfeGateFreqWindowBlocks = piLockWindowBlocks;
    cfg.FfeGateFreqExpectedRate = expectedFreqState;
    cfg.FfeGateFreqMeanHalfDiffTol = options.FreqMeanHalfDiffTol;
    cfg.FfeGateFreqStdTol = options.FreqStdTol;
    cfg.FfeGateFreqRateTol = options.FreqRateTol;
    cfg.FfeGateFreqMinBlock = 1;
    top = cdr_top(cfg);

    adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
        adcResolutionBits, adcSarPerTah, samplePerSymbol);
    adcModel.setInputMargin(0);

    appliedDriftSample = zeros(1, numBlocks);
    for sampleBlockIndex = 1:numBlocks + 1
        if sampleBlockIndex <= numBlocks
            [~, sampleUiSlip] = top.getSamplingPhase();
            firstUi = baseUi + (sampleBlockIndex - 1) * adcBlockUi + ...
                sampleUiSlip;
            % UI 内采样偏移，单位为波形样本。这里取自 PI 相位表而不是原始码，
            % 正是让 PI 非理想性（INL）可观测的关键：原始码假设码到相位是
            % 完美线性映射，那样 cdr_pi 算出来的非理想表就会在这里被丢弃。
            % 在 PiNonideal='ideal' 下该表恰好是恒等映射，
            % 于是 round(getLocalIndex()) == CodeWrapped，
            % 这一步是逐位等价的空操作。
            %
            %
            % 缓存按整数样本寻址，所以偏移要取整。在 128 samples/UI 下
            % 一个 PI code 就是一个样本、也就是一个 LSB，取整把 INL 量化到
            % +-0.5 LSB。这对几个 LSB pk-pk 量级的 INL 是够的
            % （6 LSB pk-pk 按 RMS 保留约 88%，7 个互异偏移），
            % 但会把 ~0.7 LSB pk-pk 以下的 INL 彻底抹平。
            sampleOffset = round(top.PhaseInterpolator.getLocalIndex());
            % 方案 A 的 ppm 注入：累积浮点漂移，只取整一次。
            driftSample = round(driftRatePerBlockCode * (sampleBlockIndex - 1));
            appliedDriftSample(sampleBlockIndex) = driftSample;
            blockStart = firstUi * samplePerSymbol + sampleOffset + 1 + ...
                driftSample;
            blockStop = blockStart + nominalBlockLength - 1;
            assert(blockStart >= 1 && blockStop <= numel(ctleSegment), ...
                'PI slip plus ppm drift drove the sampling window off the cache.');
            blockWaveform = ctleSegment(blockStart:blockStop);
            physicalCode = adcModel.convertOneBlockFast(blockWaveform, 1);
            centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
            out = top.processBlock(centeredCode);
        else
            out = top.flush();
        end

        if out.HasOutput
            blockIndex = out.BlockIndex;
            phaseCodeTrace(startIndex, blockIndex) = out.SampleCodeWrapped;
            uiSlipTrace(startIndex, blockIndex) = out.SampleUiSlip;
            timingErrorTrace(startIndex, blockIndex) = out.PhaseError;
            deltaCodeTrace(startIndex, blockIndex) = out.DeltaCode;
            loopControlTrace(startIndex, blockIndex) = out.LoopControl;
            loopFrequencyTrace(startIndex, blockIndex) = out.LoopFrequencyState;
            if out.LoopLockedEvent && ~isfinite(stage2GateBlock(startIndex))
                % 记录实际的第二级降档块号。离线回放门控必须先假定一条判据，
                % 而只要 FfeGateCriterion 不是所假定的那条，
                % 回放结果就是错的。
                stage2GateBlock(startIndex) = blockIndex;
            end
            if isfinite(out.SnrSettleBlock) && ...
                    ~isfinite(stage1SettleBlock(startIndex))
                % 第一级降档块号，直接取自 monitor 自己的闩锁，
                % 而不是从 SNR 轨迹反推。
                stage1SettleBlock(startIndex) = out.SnrSettleBlock;
            end
            loopCodeResidueTrace(startIndex, blockIndex) = out.LoopCodeResidue;
            loopPendingCodeTrace(startIndex, blockIndex) = out.LoopPendingCode;
            unwrappedPhaseTrace(startIndex, blockIndex) = out.UnwrappedCode;
            edgeCountTrace(startIndex, blockIndex) = sum(out.ValidTransition);
            dlevInnerTrace(startIndex, blockIndex) = out.DlevInner;
            dlevOuterTrace(startIndex, blockIndex) = out.DlevOuter;
            dlevThresholdTrace(startIndex, blockIndex) = out.DlevThreshold;
            snrDbTrace(startIndex, blockIndex) = ...
                blockDecisionSnrDb(out.Decision, out.SliceError);
            ffeCoeffTrace(startIndex, blockIndex, :) = ...
                reshape(out.FfeCoefficients, 1, 1, cdrFfeTapCount);
            driftSampleTrace(startIndex, blockIndex) = ...
                appliedDriftSample(blockIndex);
            if startIndex == histogramPhaseIndex && out.FfeAdaptationCalculated
                histogramOutputHistory = ...
                    [histogramOutputHistory, out.FfeOutput]; %#ok<AGROW>
                % 只有末 histogramTargetSamples 个样本会被用到(见下方直方图
                % 取样)，所以缓冲区超过两倍目标长度时就裁掉前面的部分。不裁
                % 的话 15000 块 x 64 样本会累积到约 96 万个元素并反复重分配,
                % 而其中 99.8% 从头到尾没人读。裁剪后缓冲区恒定含有"至少最后
                % histogramTargetSamples 个样本",因此末尾取样的结果与不裁剪
                % 时逐位相同;总样本数不足目标时从不触发裁剪，也保持原语义。
                if numel(histogramOutputHistory) > 2 * histogramTargetSamples
                    histogramOutputHistory = histogramOutputHistory( ...
                        end - histogramTargetSamples + 1:end);
                end
            end
        end
    end

    settleWindow = unwrappedPhaseTrace(startIndex, end - settleBlocks + 1:end);
    phaseSettleStd(startIndex) = std(settleWindow);

    if isZeroPpm
        % 0 ppm 时，期望频率状态为 0 且 PI 无旋转，
        % 因此旋转判据不适用，仅由频率状态
        % 判据决定(以压摆饱和为门控条件)。已于 2026-09-26 验证：
        % 该结果与已停用的 center-touch 判据 32/32 全部吻合，尾部
        % |均值| 为 8.9e-5、标准差为 2.5e-3，远在容差范围内。
        % code 域的 center-touch 锁定判据在本测试套件中已不再使用。
        [freqLockFlag(startIndex), freqDiag] = ...
            loop_monitor.detectFrequencyStateLock( ...
            loopFrequencyTrace(startIndex, :), piLockWindowBlocks, ...
            expectedFreqState, options.FreqMeanHalfDiffTol, ...
            options.FreqStdTol, options.FreqRateTol);
        tailIndex = (numBlocks - piLockWindowBlocks + 1):numBlocks;
        slewDeltaMeanAbs(startIndex) = ...
            mean(abs(deltaCodeTrace(startIndex, tailIndex)));
        slewPendingMeanAbs(startIndex) = ...
            mean(abs(loopPendingCodeTrace(startIndex, tailIndex)));
        slewSaturatedFlag(startIndex) = ...
            slewDeltaMeanAbs(startIndex) >= ...
            options.SlewSatDeltaFrac * options.MaxDeltaCode || ...
            slewPendingMeanAbs(startIndex) >= options.SlewSatPendingTol;
        lockedFlag(startIndex) = freqLockFlag(startIndex) && ...
            ~slewSaturatedFlag(startIndex);
        freqDiagList{startIndex} = freqDiag;
        rotationDiagList{startIndex} = struct('PeriodMean', NaN, ...
            'PeriodStd', NaN, 'PeriodCov', NaN, 'EventCount', 0);
        eyeTail = unwrappedPhaseTrace(startIndex, ...
            end - piLockWindowBlocks + 1:end) + ...
            driftSampleTrace(startIndex, end - piLockWindowBlocks + 1:end);
        lockedPhaseCode(startIndex) = mod(round(mean(eyeTail)), samplePerSymbol);
        piCenterDiagnostics{startIndex} = struct('CenterUnwrapped', ...
            round(mean(eyeTail)), 'FinalCount', NaN);
    else
        [freqLockFlag(startIndex), freqDiag] = ...
            loop_monitor.detectFrequencyStateLock( ...
            loopFrequencyTrace(startIndex, :), piLockWindowBlocks, ...
            expectedFreqState, options.FreqMeanHalfDiffTol, ...
            options.FreqStdTol, options.FreqRateTol);
        [rotationLockFlag(startIndex), rotationDiag] = ...
            loop_monitor.detectRotationPeriodLock( ...
            unwrappedPhaseTrace(startIndex, :), piLockWindowBlocks, ...
            samplePerSymbol, options.RotMinIntervals, options.RotCovTol, ...
            expectedRotationPeriod, rotPeriodTolBlocks);
        % 压摆饱和保护：环路若被钉在 MaxDeltaCode，或存在持续的
        % 限幅 code 堆积，则即使其
        % 频率状态与旋转周期看起来恒定，也并非真正处于跟踪状态。
        tailIndex = (numBlocks - piLockWindowBlocks + 1):numBlocks;
        slewDeltaMeanAbs(startIndex) = ...
            mean(abs(deltaCodeTrace(startIndex, tailIndex)));
        slewPendingMeanAbs(startIndex) = ...
            mean(abs(loopPendingCodeTrace(startIndex, tailIndex)));
        slewSaturatedFlag(startIndex) = ...
            slewDeltaMeanAbs(startIndex) >= ...
            options.SlewSatDeltaFrac * options.MaxDeltaCode || ...
            slewPendingMeanAbs(startIndex) >= options.SlewSatPendingTol;
        if rotationApplicable
            lockedFlag(startIndex) = freqLockFlag(startIndex) && ...
                rotationLockFlag(startIndex) && ...
                ~slewSaturatedFlag(startIndex);
        else
            % 该频偏下尾部窗口内的 PI 旋转次数过少，因此
            % 旋转周期判据不适用；仅由频率状态
            % 判据决定(同样以压摆饱和为门控条件)。
            lockedFlag(startIndex) = freqLockFlag(startIndex) && ...
                ~slewSaturatedFlag(startIndex);
        end
        freqDiagList{startIndex} = freqDiag;
        rotationDiagList{startIndex} = rotationDiag;
        eyeTail = unwrappedPhaseTrace(startIndex, end - piLockWindowBlocks + 1:end) + ...
            driftSampleTrace(startIndex, end - piLockWindowBlocks + 1:end);
        lockedPhaseCode(startIndex) = mod(round(mean(eyeTail)), samplePerSymbol);
        piCenterDiagnostics{startIndex} = struct('CenterUnwrapped', ...
            round(mean(eyeTail)), 'FinalCount', NaN);
    end

    if isZeroPpm
        modeText = 'freq-state';
        lockDetail = sprintf('freqMean=%.4g(exp%.4g) tailStd=%.3g', ...
            freqDiagList{startIndex}.MeanValue, expectedFreqState, ...
            freqDiagList{startIndex}.TailStd);
    else
        modeText = 'freq+rotation';
        lockDetail = sprintf('freqMean=%.4g(exp%.4g) cov=%.3g period=%.4g', ...
            freqDiagList{startIndex}.MeanValue, expectedFreqState, ...
            rotationDiagList{startIndex}.PeriodCov, ...
            rotationDiagList{startIndex}.PeriodMean);
    end
    fprintf(['Start phase %3d/%d [%s]: locked=%d (freq=%d rot=%d sat=%d), ' ...
        'eye phase code=%g, %s, dLev=[%.2f %.2f].\n'], startPhase, ...
        samplePerSymbol, modeText, lockedFlag(startIndex), ...
        freqLockFlag(startIndex), rotationLockFlag(startIndex), ...
        slewSaturatedFlag(startIndex), lockedPhaseCode(startIndex), ...
        lockDetail, dlevInnerTrace(startIndex, end), ...
        dlevOuterTrace(startIndex, end));
end

% 眼图相位(眼图网格中的物理采样位置) = PI 展开 code
% 加所注入的整数漂移。一旦跟踪锁定即恒定，无论 0 ppm
% (漂移为 0)还是 ppm 情形均如此；用于跨起始相位一致性校验及需求 4。
eyePhaseUnwrappedTrace = unwrappedPhaseTrace + driftSampleTrace;
driftExactTrace = repmat(driftRatePerBlockCode * (0:numBlocks - 1), ...
    numStartPhase, 1);

% 各起始相位的首次捕获(acquisition)block：取其最后一次离开
% 围绕跟踪中心的眼图相位带的位置，再对已锁定行取 argmax。
firstCaptureBlock = nan(1, numStartPhase);
piTrackingErrorTrace = zeros(numStartPhase, numBlocks);
for startIndex = 1:numStartPhase
    tailWindow = eyePhaseUnwrappedTrace(startIndex, ...
        end - piLockWindowBlocks + 1:end);
    centerC = mean(tailWindow);
    residual = eyePhaseUnwrappedTrace(startIndex, :) - centerC;
    piTrackingErrorTrace(startIndex, :) = residual;
    outside = find(abs(residual) > captureBandHalfWidth, 1, 'last');
    if isempty(outside)
        firstCaptureBlock(startIndex) = 1;
    elseif outside < numBlocks
        firstCaptureBlock(startIndex) = outside + 1;
    else
        firstCaptureBlock(startIndex) = NaN;
    end
end
eligible = find(lockedFlag & isfinite(firstCaptureBlock));
slowestIndex = NaN;
if ~isempty(eligible)
    [~, position] = max(firstCaptureBlock(eligible));
    slowestIndex = eligible(position);
end
selectionFlag = isfinite(slowestIndex);
selectedStartPhase = NaN;
selectedCaptureBlock = NaN;
if selectionFlag
    selectedStartPhase = startPhaseList(slowestIndex);
    selectedCaptureBlock = firstCaptureBlock(slowestIndex);
end

% 在下面的绘图选择逻辑把 selectedStartPhase/selectedCaptureBlock 重新指向
% 诊断图所需的最差失败行之前，先把"仅锁定"的选择结果保存到
% 结果字段。
slowestLockedStartPhase = selectedStartPhase;
slowestLockedCaptureBlock = selectedCaptureBlock;

% 绘图选择：优先选取最慢锁定捕获；若没有任何起始相位锁定
% (例如 -100 ppm 冷启动)，则退回选取最差的失败起始相位，以便
% 各起始相位诊断图仍能绘制出来供调试。对于频偏而言，"最差"
% 指的是频率状态尾部均值偏离期望跟踪速率最远的那一行；
% 0 ppm 时则指尾部相位标准差最大的那一行。
plotIndex = slowestIndex;
plotIsLocked = selectionFlag;
if ~selectionFlag
    if isZeroPpm
        [~, plotIndex] = max(phaseSettleStd);
    else
        freqMeanAll = cellfun(@(diagnostic) diagnostic.MeanValue, freqDiagList);
        [~, plotIndex] = max(abs(freqMeanAll - expectedFreqState));
    end
    selectedStartPhase = startPhaseList(plotIndex);
    selectedCaptureBlock = firstCaptureBlock(plotIndex);
end
plotSelected = isfinite(plotIndex);
% 所绘起始相位对应的 mu 降档里程碑：这两个
% 事件会改变环路步长，标出它们后即可解释收敛曲线中
% 拐点的成因：
%   阶段 1 = capture -> settle，以 SNR-EWMA 阈值为门控条件
%   阶段 2 = settle -> PVT-track，以 FfeGateCriterion 为门控条件
% 两者均对 NaN 安全：从未发生的里程碑将直接不绘制。
selectedStage1Block = NaN;
selectedStage2Block = NaN;
if plotSelected
    selectedStage1Block = stage1SettleBlock(plotIndex);
    selectedStage2Block = stage2GateBlock(plotIndex);
end
if plotIsLocked
    plotRowTag = 'slowest locked first-capture';
else
    plotRowTag = 'WORST FAILING start (not locked)';
end

lockedCodeList = lockedPhaseCode(lockedFlag);
if isempty(lockedCodeList)
    commonLockPhase = NaN;
    phaseSpread = NaN;
else
    circularSeparation = abs(mod(lockedCodeList(:) - ...
        lockedCodeList(:).' + samplePerSymbol / 2, samplePerSymbol) - ...
        samplePerSymbol / 2);
    [~, medoidIndex] = min(sum(circularSeparation, 2));
    medoidCode = lockedCodeList(medoidIndex);
    liftedLockedCode = medoidCode + mod(lockedCodeList - medoidCode + ...
        samplePerSymbol / 2, samplePerSymbol) - samplePerSymbol / 2;
    commonLockPhase = mod(floor(median(liftedLockedCode) + 0.5), ...
        samplePerSymbol);
    phaseSpread = max(liftedLockedCode) - min(liftedLockedCode);
end
commonDistance = abs(mod(lockedPhaseCode - commonLockPhase + ...
    samplePerSymbol / 2, samplePerSymbol) - samplePerSymbol / 2);
% 全相位一致性容差带：存在频偏时，注入的 +/-1..2
% code 舍入加旋转极限环会使各起始相位锁定后的眼图
% 相位比 0 ppm 抖动更宽，因此 ppm 情形下的容差带比 0 ppm 的更松。
if isZeroPpm
    allPhaseBand = 3;
else
    allPhaseBand = 16;
end
allPhaseLock = all(lockedFlag) && all(commonDistance <= allPhaseBand);

dlevInnerFinal = dlevInnerTrace(:, end).';
dlevOuterFinal = dlevOuterTrace(:, end).';
dlevInnerSpread = max(dlevInnerFinal) - min(dlevInnerFinal);
dlevOuterSpread = max(dlevOuterFinal) - min(dlevOuterFinal);
dlevConsistent = dlevInnerSpread <= 2 * dlevSettleStdTolerance && ...
    dlevOuterSpread <= 2 * dlevSettleStdTolerance;
dlevInnerTruthError = mean(dlevInnerFinal) - dlevInnerReference;
dlevOuterTruthError = mean(dlevOuterFinal) - dlevOuterReference;

ffeFinalCoefficients = reshape(ffeCoeffTrace(:, end, :), ...
    numStartPhase, cdrFfeTapCount);
ffeCoeffSpread = max(ffeFinalCoefficients, [], 1) - ...
    min(ffeFinalCoefficients, [], 1);
ffeCoeffMean = mean(ffeFinalCoefficients, 1);
ffeConsistent = max(ffeCoeffSpread) <= 2 * ffeSettleStdTolerance;
if any(lockedFlag)
    evalPhase = commonLockPhase;
else
    evalPhase = referencePhase;
end
displayEvalOffset = -3:8;
displayRegressor = buildPathRegressor(channelCtleSymbolPulse, ...
    samplePerSymbol, evalPhase, displayEvalOffset, cdrFfeTapOffset, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    laneToTimeOrder, nominalBlockLength, adcZeroCode);
displayOutputCursor = reshape(displayRegressor * ffeCoeffMean(:), 1, []);
displayNormalizedCursor = displayOutputCursor / ...
    displayOutputCursor(displayEvalOffset == 0);
if numel(histogramOutputHistory) >= histogramTargetSamples
    histogramSamples = histogramOutputHistory( ...
        end - histogramTargetSamples + 1:end);
else
    histogramSamples = histogramOutputHistory;
end

ppmTag = sprintf('%s%d', ternaryChar(options.FreqOffsetPpm >= 0, 'p', 'm'), ...
    round(abs(options.FreqOffsetPpm)));
resultDir = fullfile(testDir, 'result', ...
    sprintf('cdr_three_loop_ppm_%s', ppmTag));
if ~isempty(options.ResultDir)
    resultDir = char(options.ResultDir);
end
if options.SaveOutputs && ~exist(resultDir, 'dir')
    mkdir(resultDir);
end
convergenceFigurePath = fullfile(resultDir, 'cdr_phase_convergence.fig');
lockSummaryFigurePath = fullfile(resultDir, 'cdr_locked_phase_vs_start_phase.fig');
dlevConvergenceFigurePath = fullfile(resultDir, 'dlev_convergence.fig');
ffeConvergenceFigurePath = fullfile(resultDir, 'cdr_ffe_convergence.fig');
ffeHistogramFigurePath = fullfile(resultDir, 'cdr_ffe_output_histogram.fig');
totalPathResponseFigurePath = fullfile(resultDir, ...
    'cdr_total_path_ui_response.fig');
loopDitherFigurePath = fullfile(resultDir, 'cdr_loop_freq_state.fig');
trackingErrorFigurePath = fullfile(resultDir, 'cdr_pi_tracking_error.fig');
resultMatPath = fullfile(resultDir, 'cdr_three_loop_ppm_result.mat');

if options.SaveOutputs
    blockAxis = 1:numBlocks;
    selectedModalPhaseCode = NaN;
    if plotSelected
        selectedModalPhaseCode = lockedPhaseCode(plotIndex);
    end
    dlevInnerInit = options.DlevInnerInit;
    dlevOuterInit = options.DlevOuterInit;
    ffeInitModeLabel = lower(char(options.FfeInitMode));
    ffeAdaptEnableMask = logical(options.FfeAdaptEnableMask);

    % 图 1：所选起始相位(最慢锁定捕获，若无锁定则取最差
    % 失败起始相位)的 PI code(回绕值)收敛曲线。
    % 存在频偏时，回绕 code 呈旋转锯齿波，其
    % 周期即为跟踪到的旋转周期；0 ppm 时退化为一条水平线。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
    if plotSelected
        plot(blockAxis, phaseCodeTrace(plotIndex, :), ...
            'Color', [0.10 0.40 0.80], 'LineWidth', 0.9);
        hold on;
        yline(selectedModalPhaseCode, 'k--', ...
            sprintf('eye phase code %g', selectedModalPhaseCode), ...
            'LineWidth', 1.2);
        if isfinite(selectedCaptureBlock)
            xline(selectedCaptureBlock, 'r--', ...
                sprintf('acquisition block %g', selectedCaptureBlock), ...
                'LineWidth', 1.2);
        end
        drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
            options.SnrSettleThresholdDb, ffeGateCriterion, true);
        hold off; grid on;
        xlim([blockAxis(1) blockAxis(end)]);
        ylim([0 samplePerSymbol - 1]);
        xlabel('CDR Block Index (64 UI per block)');
        ylabel('PI Sampling Phase Code (wrapped, sample index)');
        title(sprintf(['Triple-loop CDR wrapped PI code @ %+g ppm | %s: start phase %g, ' ...
            'expected rotation period %.4g blocks/UI'], options.FreqOffsetPpm, ...
            plotRowTag, selectedStartPhase, expectedRotationPeriod));
    else
        axis off;
        text(0.5, 0.5, 'No start phase available to plot.', ...
            'Units', 'normalized', 'HorizontalAlignment', 'center', ...
            'FontWeight', 'bold');
        title(sprintf('Triple-loop CDR PI code @ %+g ppm', ...
            options.FreqOffsetPpm));
    end
    saveFigureResilient(fig, convergenceFigurePath); close(fig);

    % 图 2：锁定眼图相位 code vs 起始相位(蓝色为通过，红色为失败)。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 620]);
    plot(startPhaseList, lockedPhaseCode, '-', 'Color', [0.65 0.65 0.65], ...
        'LineWidth', 1.0);
    hold on;
    plot(startPhaseList(lockedFlag), lockedPhaseCode(lockedFlag), 'bo', ...
        'LineWidth', 1.3, 'MarkerFaceColor', 'b');
    plot(startPhaseList(~lockedFlag), lockedPhaseCode(~lockedFlag), 'rx', ...
        'LineWidth', 1.5, 'MarkerSize', 8);
    if isfinite(commonLockPhase)
        yline(commonLockPhase, 'k--', ...
            sprintf('common eye phase %g', commonLockPhase), 'LineWidth', 1.2);
    end
    hold off; grid on;
    xlim([min(startPhaseList) - 0.5 max(startPhaseList) + 0.5]);
    xlabel('Initial Sampling Phase Code');
    ylabel('Tracked eye phase code (last window)');
    title(sprintf(['Eye Phase vs Start Phase @ %+g ppm (%d/%d locked, ' ...
        'all-phase lock = %d, spread = %g code)'], options.FreqOffsetPpm, ...
        sum(lockedFlag), numStartPhase, allPhaseLock, phaseSpread));
    saveFigureResilient(fig, lockSummaryFigurePath); close(fig);

    % 图 3：所选起始相位的 dLev 收敛曲线(若无锁定则取最差
    % 失败起始相位)。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
    if plotSelected
        plot(blockAxis, dlevOuterTrace(plotIndex, :), ...
            'Color', [0.10 0.40 0.80], 'LineWidth', 1.0);
        hold on;
        plot(blockAxis, dlevInnerTrace(plotIndex, :), ...
            'Color', [0.85 0.35 0.10], 'LineWidth', 1.0);
        yline(dlevOuterReference, 'r--', ...
            sprintf('outer ref %.2f', dlevOuterReference), 'LineWidth', 1.2);
        yline(dlevInnerReference, 'r:', ...
            sprintf('inner ref %.2f', dlevInnerReference), 'LineWidth', 1.2);
        yline(dlevOuterInit, 'k--', ...
            sprintf('outer init %.2f', dlevOuterInit), 'LineWidth', 1.0);
        yline(dlevInnerInit, 'k:', ...
            sprintf('inner init %.2f', dlevInnerInit), 'LineWidth', 1.0);
        if isfinite(selectedCaptureBlock)
            xline(selectedCaptureBlock, 'r--', ...
                sprintf('acquisition block %g', selectedCaptureBlock), ...
                'LineWidth', 1.2);
        end
        drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
            options.SnrSettleThresholdDb, ffeGateCriterion, true);
        hold off; grid on;
        xlim([blockAxis(1) blockAxis(end)]);
        xlabel('CDR Block Index (64 UI per block)');
        ylabel('Adapted dLev (code domain)');
        title(sprintf(['dLev Trace @ %+g ppm | %s: start phase %g, ' ...
            'mu=%.4g->%.4g->%.4g (capture->settle->PVT)'], ...
            options.FreqOffsetPpm, plotRowTag, selectedStartPhase, ...
            options.StepSize, options.StepSizeSettle, ...
            options.DlevStepSizePvtTrack));
    else
        axis off;
        text(0.5, 0.5, 'No start phase available to plot.', 'Units', ...
            'normalized', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('dLev Trace: no data');
    end
    saveFigureResilient(fig, dlevConvergenceFigurePath); close(fig);

    % 图 4：所选起始相位的 CDR FFE 系数收敛曲线。
    freeTapIndexList = find(ffeAdaptEnableMask);
    numFreeTap = numel(freeTapIndexList);
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 720]);
    if plotSelected
        tiledLayout = tiledlayout(fig, numFreeTap, 1, ...
            'TileSpacing', 'compact', 'Padding', 'compact');
        for freeIdx = 1:numFreeTap
            tapIndex = freeTapIndexList(freeIdx);
            nexttile(tiledLayout);
            tapTrace = reshape(ffeCoeffTrace(plotIndex, :, tapIndex), ...
                1, numBlocks);
            plot(blockAxis, tapTrace, 'Color', [0.10 0.40 0.80], 'LineWidth', 0.9);
            hold on;
            yline(cdrFfeCoefficients(tapIndex), 'k--', ...
                sprintf('offline %.4f', cdrFfeCoefficients(tapIndex)), ...
                'LineWidth', 1.1);
            if isfinite(selectedCaptureBlock)
                xline(selectedCaptureBlock, 'r--', 'LineWidth', 1.0);
            end
            drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
                options.SnrSettleThresholdDb, ffeGateCriterion, false);
            hold off; grid on;
            xlim([blockAxis(1) blockAxis(end)]);
            thisOffset = cdrFfeTapOffset(tapIndex);
            if thisOffset < 0
                tapName = sprintf('pre%d tap', -thisOffset);
            elseif thisOffset > 0
                tapName = sprintf('post%d tap', thisOffset);
            else
                tapName = 'main tap';
            end
            ylabel(sprintf('%s (offset %+d)', tapName, thisOffset));
            if freeIdx == 1
                title(tiledLayout, sprintf(['CDR FFE Trace @ %+g ppm | %s: start ' ...
                    'phase %g, %s, mu=%.3g->%.3g'], options.FreqOffsetPpm, ...
                    plotRowTag, selectedStartPhase, ffeInitModeLabel, ...
                    options.FfeStepSize, options.FfeStepSizeSettle));
            end
            if freeIdx == numFreeTap
                xlabel('CDR Block Index (64 UI per block)');
            end
        end
    else
        axis off;
        text(0.5, 0.5, 'No start phase available to plot.', 'Units', ...
            'normalized', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('CDR FFE Trace: no data');
    end
    saveFigureResilient(fig, ffeConvergenceFigurePath); close(fig);

    % 图 5：收敛后的 CDR FFE 输出直方图(ppm 情形下相位持续旋转)。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 620]);
    ax = axes(fig);
    if ~isempty(histogramSamples)
        histogram(ax, histogramSamples, 'BinMethod', 'integers', ...
            'FaceColor', [0.2 0.4 0.8], 'EdgeColor', 'none');
        hold(ax, 'on');
        [hRefLine, hConvLine] = addDlevHistogramReferenceLines(ax, ...
            levelCenter, dlevInnerFinal(histogramPhaseIndex), ...
            dlevOuterFinal(histogramPhaseIndex));
        legend(ax, [hRefLine hConvLine], ...
            {'offline-optimal reference level', 'online-converged dlev level'}, ...
            'Location', 'best', 'AutoUpdate', 'off', 'FontSize', 8);
        hold(ax, 'off');
    end
    grid(ax, 'on');
    xlabel(ax, 'Converged CDR FFE Output (code domain)');
    ylabel(ax, 'Sample Count');
    title(ax, sprintf(['Converged CDR FFE Output Histogram @ %+g ppm ' ...
        '(start phase %g, %d samples, phase rotates under offset)'], ...
        options.FreqOffsetPpm, startPhaseList(histogramPhaseIndex), ...
        numel(histogramSamples)));
    saveFigureResilient(fig, ffeHistogramFigurePath); close(fig);

    % 图 6：在跟踪到的眼图相位处评估的全路径单 UI 响应。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 620]);
    stemHandle = stem(displayEvalOffset, displayNormalizedCursor, 'filled', ...
        'LineWidth', 1.3, 'Color', [0.2 0.4 0.8]);
    stemHandle.MarkerSize = 6;
    hold on;
    stem(0, displayNormalizedCursor(displayEvalOffset == 0), 'filled', ...
        'LineWidth', 1.6, 'Color', [0.85 0.2 0.2], 'MarkerSize', 8);
    yline(0, 'k--', 'pre1/post1 target 0 (SS-LMS ISI-null)', 'LineWidth', 1.0);
    for cursorIdx = 1:numel(displayEvalOffset)
        text(displayEvalOffset(cursorIdx), displayNormalizedCursor(cursorIdx), ...
            sprintf('%.3f', displayNormalizedCursor(cursorIdx)), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontSize', 7);
    end
    hold off; grid on;
    xlim([displayEvalOffset(1) - 0.5, displayEvalOffset(end) + 0.5]);
    xticks(displayEvalOffset);
    xlabel('Cursor Offset (UI, 0 = main)');
    ylabel('Normalized Total-Path Response (main = 1)');
    title(sprintf(['Total-Path Unit-UI Response @ %+g ppm | evaluated @ ' ...
        'eye phase %g (S-curve ref %d)'], options.FreqOffsetPpm, evalPhase, ...
        referencePhase));
    saveFigureResilient(fig, totalPathResponseFigurePath); close(fig);

    % 图 7：环路频率状态(ppm 锁定观测量)及环路
    % control 与 code residue。尾窗的平均频率态就等于环路为跟踪该频偏
    % 而提供的稳态定时速率。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 780]);
    if plotSelected
        freqLayout = tiledlayout(fig, 3, 1, ...
            'TileSpacing', 'compact', 'Padding', 'compact');
        tailWindow = max(1, numBlocks - piLockWindowBlocks + 1):numBlocks;
        freq = loopFrequencyTrace(plotIndex, :);
        ctrl = loopControlTrace(plotIndex, :);
        resid = loopCodeResidueTrace(plotIndex, :);
        tailMeanFreq = mean(freq(tailWindow));

        nexttile(freqLayout);
        plot(blockAxis, freq, 'Color', [0.85 0.35 0.10], 'LineWidth', 0.9);
        hold on;
        yline(tailMeanFreq, 'r--', ...
            sprintf('tail mean %.4g code/block', tailMeanFreq), 'LineWidth', 1.2);
        yline(expectedFreqState, 'k--', ...
            sprintf('expected %.4g code/block', expectedFreqState), ...
            'LineWidth', 1.0);
        if isfinite(selectedCaptureBlock)
            xline(selectedCaptureBlock, 'r--', 'LineWidth', 1.0);
        end
        drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
            options.SnrSettleThresholdDb, ffeGateCriterion, false);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylabel('FrequencyState (code/block)');
        title(freqLayout, sprintf(['Loop frequency state @ %+g ppm | %s: start ' ...
            'phase %g | tail mean %.4g vs expected %.4g code/block'], ...
            options.FreqOffsetPpm, plotRowTag, selectedStartPhase, tailMeanFreq, ...
            expectedFreqState));

        nexttile(freqLayout);
        plot(blockAxis, ctrl, 'Color', [0.10 0.40 0.80], 'LineWidth', 0.7);
        hold on; yline(0, 'k--', 'LineWidth', 1.0);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylabel('LoopControl (code/block)');

        nexttile(freqLayout);
        plot(blockAxis, resid, 'Color', [0.2 0.6 0.3], 'LineWidth', 0.7);
        hold on; yline(0, 'k--', 'LineWidth', 1.0);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylim([-1 1]);
        ylabel('CodeResidue (sub-code)');
        xlabel('CDR Block Index (64 UI per block)');
    else
        axis off;
        text(0.5, 0.5, 'No start phase available to plot.', 'Units', ...
            'normalized', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('Loop frequency state: no data');
    end
    saveFigureResilient(fig, loopDitherFigurePath); close(fig);

    % 图 8（需求 4，仅诊断，不是锁定判据）：
    % PI 实际 code 减去理想频偏补偿 code。理想 PI code 会把眼相位保持恒定，
    % 所以一旦跟上，该残差就是平的；还在捕获时则是一条斜坡。
    % 选中的起始相位用粗线，其余全部起始相位用淡色细线。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
    hold on;
    for startIndex = 1:numStartPhase
        plot(blockAxis, piTrackingErrorTrace(startIndex, :), ...
            'Color', [0.75 0.80 0.88], 'LineWidth', 0.5);
    end
    if plotSelected
        plot(blockAxis, piTrackingErrorTrace(plotIndex, :), ...
            'Color', [0.10 0.40 0.80], 'LineWidth', 1.1);
        if isfinite(selectedCaptureBlock)
            xline(selectedCaptureBlock, 'r--', ...
                sprintf('acquisition block %g', selectedCaptureBlock), ...
                'LineWidth', 1.2);
        end
        drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
            options.SnrSettleThresholdDb, ffeGateCriterion, true);
    end
    yline(0, 'k--', 'ideal offset-compensated PI code', 'LineWidth', 1.0);
    yline(captureBandHalfWidth, 'k:', 'LineWidth', 0.8);
    yline(-captureBandHalfWidth, 'k:', 'LineWidth', 0.8);
    hold off; grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('PI actual code - ideal offset code (sample)');
    title(sprintf(['PI Tracking Error vs Ideal Offset Code @ %+g ppm | %s ' ...
        '(diagnostic only; flat = tracked, ramp = acquiring)'], ...
        options.FreqOffsetPpm, plotRowTag));
    saveFigureResilient(fig, trackingErrorFigurePath); close(fig);
end

result = struct();
result.RunnerName = 'cdr_three_loop_ppm';
result.CachePath = cachePath;
result.FreqOffsetPpm = options.FreqOffsetPpm;
result.DriftRatePerBlockCode = driftRatePerBlockCode;
result.ExpectedFreqState = expectedFreqState;
result.ExpectedRotationPeriodBlocks = expectedRotationPeriod;
result.DriftBudgetUi = driftBudgetUi;
result.IsZeroPpm = isZeroPpm;
result.LockMode = ternaryChar(isZeroPpm, 'freq-state', 'freq+rotation');
result.RotationCriterionApplicable = rotationApplicable;
result.RotPeriodTolBlocks = rotPeriodTolBlocks;
result.SlewUtilization = slewUtilization;
result.SaturatedRotationPeriodBlocks = saturatedRotationPeriod;
result.SlewSaturatedFlag = slewSaturatedFlag;
result.SlewDeltaMeanAbs = slewDeltaMeanAbs;
result.SlewPendingMeanAbs = slewPendingMeanAbs;
result.AnalysisStartUi = analysisStartUi;
result.AnalysisNumUi = analysisNumUi;
result.SamplePerSymbol = samplePerSymbol;
% 采样地址描述符。保存下来是为了让离线消费者能重建每块的缓存波形地址，
% 而不必回到 runner 源码里重新推导常量
% （参见 helpers/build_ppm_eye_set.m）。
result.AdcBlockUi = adcBlockUi;
result.CdrFfePreTapCount = cdrFfePreTapCount;
result.ReferencePhase = referencePhase;
result.EvalPhase = evalPhase;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.CdrFfeTapOffset = cdrFfeTapOffset;
result.CdrFfeMainTapIndex = cdrFfeMainTapIndex;
result.FfeInitMode = lower(char(options.FfeInitMode));
result.FfeInitCoefficients = ffeInitCoefficients;
result.FfeStepSize = options.FfeStepSize;
result.FfeStepSizeSettle = options.FfeStepSizeSettle;
result.SnrSettleThresholdDb = options.SnrSettleThresholdDb;
result.SnrSettleAlpha = options.SnrSettleAlpha;
result.SnrSettleMinBlock = options.SnrSettleMinBlock;
result.DlevStepSizePvtTrack = options.DlevStepSizePvtTrack;
result.FfeAdaptEnableMask = logical(options.FfeAdaptEnableMask);
result.LevelCenter = levelCenter;
result.DlevInnerReference = dlevInnerReference;
result.DlevOuterReference = dlevOuterReference;
result.DlevInnerInit = options.DlevInnerInit;
result.DlevOuterInit = options.DlevOuterInit;
result.LoopKp = options.Kp;
result.LoopKi = options.Ki;
result.LoopMaxDeltaCode = options.MaxDeltaCode;
result.LoopFrequencyLimit = options.FrequencyLimit;
result.PdPolarity = options.Polarity;
result.DlevStepSize = options.StepSize;
result.DlevStepSizeSettle = options.StepSizeSettle;
result.PiNumBit = 7;
result.BaseUi = baseUi;
result.UiGuard = uiGuard;
result.NumBlocks = numBlocks;
result.StartPhaseList = startPhaseList;
result.PhaseCodeTrace = phaseCodeTrace;
result.UiSlipTrace = uiSlipTrace;
result.UnwrappedPhaseTrace = unwrappedPhaseTrace;
result.DriftSampleTrace = driftSampleTrace;
result.DriftExactTrace = driftExactTrace;
result.EyePhaseUnwrappedTrace = eyePhaseUnwrappedTrace;
result.PiTrackingErrorTrace = piTrackingErrorTrace;
result.TimingErrorTrace = timingErrorTrace;
result.DeltaCodeTrace = deltaCodeTrace;
result.LoopControlTrace = loopControlTrace;
result.LoopFrequencyStateTrace = loopFrequencyTrace;
result.LoopCodeResidueTrace = loopCodeResidueTrace;
result.LoopPendingCodeTrace = loopPendingCodeTrace;
result.EdgeCountTrace = edgeCountTrace;
result.SnrDbTrace = snrDbTrace;
result.DlevInnerTrace = dlevInnerTrace;
result.DlevOuterTrace = dlevOuterTrace;
result.DlevThresholdTrace = dlevThresholdTrace;
result.FfeCoeffTrace = ffeCoeffTrace;
result.SettleBlocks = settleBlocks;
result.LockWindowBlocks = piLockWindowBlocks;
result.LockMinEvents = piLockMinEvents;
result.LockBandHalfWidth = piLockBandHalfWidth;
result.CaptureBandHalfWidth = captureBandHalfWidth;
result.FreqLockFlag = freqLockFlag;
result.RotationLockFlag = rotationLockFlag;
result.FreqLockDiagnostics = [freqDiagList{:}];
result.RotationLockDiagnostics = [rotationDiagList{:}];
result.PiCenterDiagnostics = [piCenterDiagnostics{:}];
result.FirstCaptureBlock = firstCaptureBlock;
result.Stage2GateBlock = stage2GateBlock;
result.Stage1SettleBlock = stage1SettleBlock;
result.SlowestCapturePhaseIndex = slowestIndex;
result.SlowestCaptureStartPhase = slowestLockedStartPhase;
result.SlowestFirstCaptureBlock = slowestLockedCaptureBlock;
% 在逐起始相位诊断图中被单独画出的那一行：捕获最慢的已锁定相位；
% 若一个都没锁定，则取最差的失败相位以便调试。
result.PlotStartPhaseIndex = plotIndex;
result.PlotStartPhase = selectedStartPhase;
result.PlotIsLocked = plotIsLocked;
result.PhaseSettleStd = phaseSettleStd;
result.LockedPhaseCode = lockedPhaseCode;
result.LockedFlag = lockedFlag;
result.CommonLockPhase = commonLockPhase;
result.PhaseSpread = phaseSpread;
result.AllPhaseBandCode = allPhaseBand;
result.AllPhaseLock = allPhaseLock;
result.AllStartsConverged = all(lockedFlag);
result.RunOptions = options;
result.DlevInnerFinal = dlevInnerFinal;
result.DlevOuterFinal = dlevOuterFinal;
result.DlevInnerSpread = dlevInnerSpread;
result.DlevOuterSpread = dlevOuterSpread;
result.DlevInnerTruthError = dlevInnerTruthError;
result.DlevOuterTruthError = dlevOuterTruthError;
result.DlevConsistent = dlevConsistent;
result.FfeFinalCoefficients = ffeFinalCoefficients;
result.FfeCoeffMean = ffeCoeffMean;
result.FfeCoeffSpread = ffeCoeffSpread;
result.FfeConsistent = ffeConsistent;
result.DisplayEvalOffset = displayEvalOffset;
result.DisplayNormalizedCursor = displayNormalizedCursor;
result.HistogramPhaseIndex = histogramPhaseIndex;
result.HistogramSamples = histogramSamples;
result.ConvergenceFigurePath = convergenceFigurePath;
result.LockSummaryFigurePath = lockSummaryFigurePath;
result.DlevConvergenceFigurePath = dlevConvergenceFigurePath;
result.FfeConvergenceFigurePath = ffeConvergenceFigurePath;
result.FfeHistogramFigurePath = ffeHistogramFigurePath;
result.TotalPathResponseFigurePath = totalPathResponseFigurePath;
result.LoopFreqStateFigurePath = loopDitherFigurePath;
result.TrackingErrorFigurePath = trackingErrorFigurePath;
result.ResultMatPath = resultMatPath;
% 本次运行最终生效的第二级门控判据，记录下来是为了让保存的结果
% 能自描述它的 Stage2 块号是由哪条门控产生的。
result.FfeGateCriterion = ffeGateCriterion;
% 实际施加的 PI 非理想性。波形地址现在取自 PI 相位表，
% 所以这个字段会改变仿真出来的采样时刻。
result.PiNonideal = piNonideal;

if options.SaveOutputs
    % 旧的 ppm_lock_summary.csv 已移除：helpers/
    % write_ppm_lock_summary_txt.m 会输出 ppm_lock_summary.txt，
    % 它以人可读的逐起始相位形式给出那些列的严格超集，
    % 并且全部从这份结果 MAT 重新计算得到。
    save(resultMatPath, 'result', '-v7.3');
end

fprintf(['cdr_three_loop_ppm @ %+g ppm completed: %d/%d start phases locked ' ...
    '(all-phase lock = %d).\n'], options.FreqOffsetPpm, sum(lockedFlag), ...
    numStartPhase, allPhaseLock);
end

function snrDb = blockDecisionSnrDb(decision, sliceError)
%BLOCKDECISIONSNRDB 单块的判决导向眼质量 FOM。
%   两个输入都已经只含有效样本：cdr_top 在切片前先对 FFE 输出做掩码
%   （ffeOutput = blockOutput(blockValid)），所以 decision 与 sliceError
%   只携带已稳定的抽头。该 FOM 是判决电平功率比切片误差功率，单位 dB。
%
%
%   这是判决导向而非真值参考：眼睛闭合、样本被判到错误电平时，
%   误差是相对那个错误电平算的，读数可能偏乐观。
%   任何基于该 FOM 的 settle 门控都必须用一段已知闭眼的窗口去验证，
%   而不能想当然地假设它单调。
%
decision = double(decision(:));
sliceError = double(sliceError(:));
if isempty(decision) || isempty(sliceError)
    snrDb = NaN;
    return;
end
errorPower = mean(sliceError .^ 2);
if errorPower <= 0
    snrDb = Inf;
    return;
end
snrDb = 10 * log10(mean(decision .^ 2) / errorPower);
end

function options = parseLoopOptions(varargin)
defaults = struct();
defaults.FreqOffsetPpm = 100;
defaults.Kp = 8.0;
defaults.Ki = 0.03;
defaults.MaxDeltaCode = 1;
defaults.FrequencyLimit = 4;
defaults.Polarity = 1;
% MMPD 跳变筛选。true 只保留对称的 -3<->+3 与 -1<->+1 跳变
%（PD 样本更少但更干净，ISI 引入的偏置更低）；
% false 使用全部非静止跳变（每块 PD 样本约多 3 倍，方差更低，
% 但非对称跳变会带来它们自己的偏置）。在冷启动 FFE 下，
% 对称筛选还额外依赖极端符号被判对，
% 而这恰恰正是闭眼会破坏的前提。
defaults.TransitionFilter = true;
defaults.StepSize = 0.5;
defaults.StepSizeSettle = 0.1;
% 两级 mu 降档。
%   第一级（capture -> settle）以眼质量为门控条件：判决导向 SNR 的平均值
%   越过 SnrSettleThresholdDb。旧的 outer-dLev 位移门控已于 2026-09-26
%   从 cdr_top 移除；它触发时所依据的漂移速率是眼睛还没挣来的
%   （在 -100 ppm 实测：block 84 就触发，此时 dLev 还剩 59% 行程，
%   却把 FFE 步长砍掉 20 倍，眼睛就此张不开，
%   导致没有任何起始相位能完成捕获）。
%   第二级（settle -> PVT track）复用已有的相位带锁定门控（FfeGate*），
%   把两个环路再次降到只够跟踪的步长。
defaults.SnrSettleThresholdDb = 15;
defaults.SnrSettleAlpha = 1 / 128;
defaults.SnrSettleMinBlock = 200;
defaults.DlevStepSizePvtTrack = 0.02;
defaults.DlevPolarity = 1;
defaults.DlevOuterInit = 48;
defaults.DlevInnerInit = 16;
% CDR FFE 的捕获期 mu。这里刻意取成比 cdr_top 库默认值（0.004）小 4 倍，
% 因为主抽头是冻结的（FfeAdaptEnableMask 第 3 位 = 0），
% 环路重塑脉冲的唯一手段就是把前后抽头做大，
% 而这会让有效游标走位，进而移动 MMPD 的零点。
% 走位量正比于捕获步长：0 ppm 下 8 个起始相位的锁定相位离散度实测为
% 0.001 / 0.002 / 0.004 / 0.008 分别对应 3 / 6 / 12 / 21 个码，
% 在 +100 ppm 下呈现同样的单调趋势。0.001 是仍能让所有 ppm 工况
% 都留在捕获带内的最大步长。
%
defaults.FfeStepSize = 0.001;
defaults.FfeStepSizeSettle = 0.0002;
defaults.FfeAdaptEnableMask = logical([1 1 0 1 1 1]);
defaults.FfeInitMode = 'planB';
defaults.FfeBiasScale = 0;
defaults.FfeFreezeEnable = true;
defaults.FfeFreezeMinModeOccurrences = 500;
defaults.FfeFreezeMinEvents = 100;
defaults.FfeFreezeBandHalfWidth = 3;
defaults.FfeFreezeMode = 'pvt-track';
defaults.FfeStepSizePvtTrack = 0.0002;
% PI 相位表非理想性：'ab_constant'（cdr_pi 的物理 a+b=1 atan2 模型，
% INL 为 2.891 LSB pk-pk）或 'ideal'（严格线性）。
defaults.PiNonideal = 'ab_constant';
defaults.LockWindowBlocks = 2000;
defaults.FreqMeanHalfDiffTol = 0.03;
defaults.FreqStdTol = 0.08;
defaults.FreqRateTol = 0.12;
defaults.RotMinIntervals = 6;
defaults.RotCovTol = 0.15;
% 旋转周期的匹配容差。取期望周期的一个比例，而不是绝对块数：
% 绝对容差会让 slew 饱和的环路蒙混过关
%（MaxDeltaCode=1 时 PI 恰好每块走 1 个码，于是旋转周期被钉死在
% 恰好 SamplesPerSymbol 块上，它可能正好落在期望周期的一个宽松绝对
% 窗口内，而此时环路根本没有在跟踪）。
% 把 RotPeriodTol 设为非空可改回用绝对块数覆盖。
defaults.RotPeriodTolFrac = 0.03;
defaults.RotPeriodTol = [];
% slew 饱和守卫：若环路每块的 PI 增量被钉在 MaxDeltaCode 上，
% 或者 PendingCode 里持续积压被限幅吃掉的整数码，
% 那它就不可能在跟踪该频偏，一律取消其锁定资格。
defaults.SlewSatDeltaFrac = 0.98;
defaults.SlewSatPendingTol = 0.5;
defaults.SaveOutputs = true;
defaults.ResultDir = '';
defaults.StartPhaseList = [];
defaults.StartPhaseStep = 16;
defaults.CosimDir = 'channel_ctle_cosim_prbs22';
defaults.NumBlock = 15000;
defaults.AnalysisNumUi = [];
options = defaults;
providedNames = {};
if isscalar(varargin) && isstruct(varargin{1})
    provided = varargin{1};
    providedNames = fieldnames(provided);
    for index = 1:numel(providedNames)
        options.(providedNames{index}) = provided.(providedNames{index});
    end
elseif ~isempty(varargin)
    assert(mod(numel(varargin), 2) == 0, ...
        'Loop options must be name/value pairs.');
    providedNames = varargin(1:2:end);
    for index = 1:2:numel(varargin)
        options.(varargin{index}) = varargin{index + 1};
    end
end
gaveAnalysisNumUi = any(strcmp('AnalysisNumUi', providedNames)) && ...
    ~isempty(options.AnalysisNumUi);
expectedAnalysisNumUi = analysisUiFor(options.NumBlock, ...
    options.FreqOffsetPpm);
if ~gaveAnalysisNumUi
    options.AnalysisNumUi = expectedAnalysisNumUi;
else
    assert(options.AnalysisNumUi == expectedAnalysisNumUi, ...
        'AnalysisNumUi is inconsistent with NumBlock and FreqOffsetPpm.');
end
end

function analysisNumUi = analysisUiFor(numBlock, freqOffsetPpm)
adcBlockUi = 64;
driftBudgetUi = ceil(abs(freqOffsetPpm) * 1e-6 * numBlock * adcBlockUi);
% 把双侧漂移余量向上取整到整数个 64-UI ADC 块，
% 使固定的分析段永远只包含完整的块。
marginUi = ceil(2 * driftBudgetUi / adcBlockUi) * adcBlockUi;
analysisNumUi = numBlock * adcBlockUi + 512 + marginUi;
end

function validateOptions(options)
validateattributes(options.FreqOffsetPpm, {'numeric'}, ...
    {'scalar', 'real', 'finite'});
validateattributes(options.NumBlock, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', 'positive'});
validateattributes(options.AnalysisNumUi, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', 'positive'});
validateattributes(options.StartPhaseStep, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', '>=', 1, '<=', 128});
if ~isempty(options.StartPhaseList)
    validateattributes(options.StartPhaseList, {'numeric'}, ...
        {'vector', 'real', 'finite', 'integer', '>=', 0, '<', 128});
end
validateattributes(options.LockWindowBlocks, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', 'positive'});
validateattributes(options.MaxDeltaCode, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', 'positive'});
validateattributes(options.RotPeriodTolFrac, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'nonnegative'});
if ~isempty(options.RotPeriodTol)
    validateattributes(options.RotPeriodTol, {'numeric'}, ...
        {'scalar', 'real', 'nonnegative'});
end
validateattributes(options.SlewSatDeltaFrac, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive', '<=', 1});
validateattributes(options.SlewSatPendingTol, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'nonnegative'});
validateattributes(options.SaveOutputs, {'numeric', 'logical'}, ...
    {'scalar', 'real', 'finite'});
assert(any(double(options.SaveOutputs) == [0 1]), ...
    'SaveOutputs must be logical or numeric 0/1.');
assert(any(strcmpi(char(options.FfeFreezeMode), {'freeze', 'pvt-track'})), ...
    'FfeFreezeMode must be freeze or pvt-track.');
end

function value = ternaryChar(condition, trueText, falseText)
if condition
    value = trueText;
else
    value = falseText;
end
end

function flag = getCachePeriodFlag(cacheFile)
names = who(cacheFile);
if ismember('isCompletePrbsPeriod', names)
    flag = cacheFile.isCompletePrbsPeriod;
else
    flag = cacheFile.isCompletePrbs20Period;
end
end

function outputValid = processOnePhase(segment, phase, samplePerSymbol, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, blockUi)
numUi = floor((numel(segment) - phase - 1) / samplePerSymbol) + 1;
numBlocks = floor(numUi / blockUi);
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
ffeModel = cdr_ffe(cdrFfeCoefficients, cdrFfePreTapCount);
postTapCount = ffeModel.PostTapCount;
codeStream = zeros(1, numBlocks * blockUi);
for blockIndex = 1:numBlocks
    firstUi = (blockIndex - 1) * blockUi;
    blockStart = firstUi * samplePerSymbol + phase + 1;
    blockStop = blockStart + nominalBlockLength - 1;
    physicalCode = adcModel.convertOneBlockFast( ...
        segment(blockStart:blockStop), 1);
    centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
    codeStream((blockIndex - 1) * blockUi + (1:blockUi)) = centeredCode;
end
inputWindow = [zeros(1, postTapCount), codeStream, ...
    zeros(1, cdrFfePreTapCount)];
outputBlock = ffeModel.processBlock(inputWindow);
valid = true(1, numel(outputBlock));
valid(1:postTapCount) = false;
valid(end - cdrFfePreTapCount + 1:end) = false;
outputValid = outputBlock(valid);
end

function [laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol)
laneNumber = 1:adcLaneCount;
numTah = adcLaneCount / adcSarPerTah;
lanePhaseIndex = floor((laneNumber - 1) / adcSarPerTah) + 1;
laneSarIndex = mod(laneNumber - 1, adcSarPerTah) + 1;
laneTimeOrderIndex = (laneSarIndex - 1) * numTah + lanePhaseIndex;
[~, laneToTimeOrder] = sort(laneTimeOrderIndex);
nominalBlockLength = (adcLaneCount - 1) * samplePerSymbol + 1;
end

function sample = samplePulseAtPhase(pulse, samplePerSymbol, phase, offset)
[~, pulsePeakIndex] = max(abs(pulse));
mainUi = round((pulsePeakIndex - 1 - phase) / samplePerSymbol);
mainIndex = mainUi * samplePerSymbol + phase + 1;
sampleIndex = mainIndex + offset * samplePerSymbol;
assert(sampleIndex(1) >= 1 && sampleIndex(end) <= numel(pulse), ...
    'Requested symbol-pulse cursor window exceeds available data.');
sample = reshape(pulse(sampleIndex), 1, []);
end

function regressor = buildPathRegressor(symbolPulse, samplePerSymbol, ...
    phase, evalOffset, tapOffset, adcLaneCount, adcSarPerTah, ...
    adcResolutionBits, adcFullRange, laneToTimeOrder, nominalBlockLength, ...
    adcZeroCode)
channelOffset = (evalOffset(1) - tapOffset(end)): ...
    (evalOffset(end) - tapOffset(1));
analog = samplePulseAtPhase(symbolPulse, samplePerSymbol, phase, channelOffset);
codeQuantized = quantizeSamplesWithTiAdc(analog, adcLaneCount, ...
    adcSarPerTah, adcResolutionBits, adcFullRange, samplePerSymbol, ...
    laneToTimeOrder, nominalBlockLength);
codeCentered = codeQuantized - adcZeroCode;
regressor = zeros(numel(evalOffset), numel(tapOffset));
for row = 1:numel(evalOffset)
    for column = 1:numel(tapOffset)
        requiredOffset = evalOffset(row) - tapOffset(column);
        channelIndex = find(channelOffset == requiredOffset, 1);
        regressor(row, column) = codeCentered(channelIndex);
    end
end
end

function code = quantizeSamplesWithTiAdc(sample, adcLaneCount, ...
    adcSarPerTah, adcResolutionBits, adcFullRange, samplePerSymbol, ...
    laneToTimeOrder, nominalBlockLength)
assert(numel(sample) <= adcLaneCount, ...
    'Cursor sample count exceeds one TI ADC block.');
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
waveform = zeros(1, nominalBlockLength);
sampleLocation = 1 + (0:adcLaneCount - 1) * samplePerSymbol;
waveform(sampleLocation(1:numel(sample))) = sample;
physicalCode = adcModel.convertOneBlockFast(waveform, 1);
timeOrderedCode = double(physicalCode(laneToTimeOrder));
code = timeOrderedCode(1:numel(sample));
end

function [coefficients, design] = optimizeCdrFfe( ...
    channelCursor, channelOffset, tapOffset, evalOffset)
mainTapIndex = find(tapOffset == 0, 1);
freeTapMask = tapOffset ~= 0;
regressor = zeros(numel(evalOffset), numel(tapOffset));
for row = 1:numel(evalOffset)
    for column = 1:numel(tapOffset)
        requiredOffset = evalOffset(row) - tapOffset(column);
        channelIndex = find(channelOffset == requiredOffset, 1);
        regressor(row, column) = channelCursor(channelIndex);
    end
end
freeRegressor = regressor(:, freeTapMask);
fixedMainResponse = regressor(:, mainTapIndex);
pre1Row = find(evalOffset == -1, 1);
mainRow = find(evalOffset == 0, 1);
post1Row = find(evalOffset == 1, 1);
constraintMatrix = [ ...
    freeRegressor(pre1Row, :) - 0.05 * freeRegressor(mainRow, :); ...
    freeRegressor(post1Row, :) - 0.05 * freeRegressor(mainRow, :)];
constraintTarget = -[ ...
    fixedMainResponse(pre1Row) - 0.05 * fixedMainResponse(mainRow); ...
    fixedMainResponse(post1Row) - 0.05 * fixedMainResponse(mainRow)];
otherCursorMask = ~ismember(evalOffset, [-1 0 1]);
objectiveMatrix = freeRegressor(otherCursorMask, :);
objectiveTarget = fixedMainResponse(otherCursorMask);
normalMatrix = objectiveMatrix.' * objectiveMatrix;
regularizationScale = max(trace(normalMatrix) / size(normalMatrix, 1), eps);
regularization = 1e-8 * regularizationScale;
kktMatrix = [normalMatrix + regularization * eye(size(normalMatrix)), ...
    constraintMatrix.'; constraintMatrix, zeros(size(constraintMatrix, 1))];
kktTarget = [-objectiveMatrix.' * objectiveTarget; constraintTarget];
kktSolution = kktMatrix \ kktTarget;
coefficients = zeros(1, numel(tapOffset));
coefficients(mainTapIndex) = 1;
coefficients(freeTapMask) = kktSolution(1:nnz(freeTapMask));
outputCursor = reshape(regressor * coefficients(:), 1, []);
normalizedCursor = outputCursor / outputCursor(mainRow);
design = struct('TapOffset', tapOffset, 'EvalOffset', evalOffset, ...
    'Regularization', regularization, 'Regressor', regressor, ...
    'OutputCursor', outputCursor, 'NormalizedCursor', normalizedCursor, ...
    'OtherCursorRms', sqrt(mean(normalizedCursor(otherCursorMask) .^ 2)), ...
    'OtherCursorMax', max(abs(normalizedCursor(otherCursorMask))));
end

function center = estimatePam4Centers(sample)
center = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    [~, cluster] = min(abs(sample(:) - center), [], 2);
    updated = center;
    for level = 1:4
        levelSample = sample(cluster == level);
        if ~isempty(levelSample)
            updated(level) = mean(levelSample);
        end
    end
    if max(abs(updated - center)) < 1e-12
        break;
    end
    center = updated;
end
center = sort(center);
end

function [refHandle, convHandle] = addDlevHistogramReferenceLines(ax, ...
    levelCenter, dlevInnerFinalValue, dlevOuterFinalValue)
refHandle = xline(ax, levelCenter(1), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
xline(ax, levelCenter(2), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
xline(ax, levelCenter(3), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
xline(ax, levelCenter(4), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
convHandle = xline(ax, -dlevOuterFinalValue, 'r--', 'LineWidth', 1.0);
xline(ax, -dlevInnerFinalValue, 'r--', 'LineWidth', 1.0);
xline(ax, dlevInnerFinalValue, 'r--', 'LineWidth', 1.0);
xline(ax, dlevOuterFinalValue, 'r--', 'LineWidth', 1.0);
end

function saveFigureResilient(figureHandle, filePath)
set(figureHandle, 'Visible', 'on');
maxAttempts = 5;
for attempt = 1:maxAttempts
    try
        savefig(figureHandle, filePath);
        return;
    catch saveError
        if attempt == maxAttempts
            warning('cdr_three_loop_ppm:FigureSaveFailed', ...
                'Could not save "%s": %s', filePath, saveError.message);
            return;
        end
        pause(0.5);
    end
end
end

function drawStageMarkers(stage1Block, stage2Block, snrThresholdDb, ...
        gateCriterion, labeled)
%DRAWSTAGEMARKERS 在以块为横轴的图上标出两个 mu 降档里程碑。
%
% 收敛曲线会在两次步长降档处改变斜率，把它们标出来可以让这些拐点
% 有据可查，而不是看起来莫名其妙：
%   第一级：capture -> settle，由 SNR-EWMA 阈值门控
%          （dLev 0.5 -> 0.1，FFE 1e-3 -> 2e-4）
%   第二级：settle -> PVT-track，由 FfeGateCriterion 门控
%          （dLev 0.1 -> 0.02；默认调参下 FFE 不变）
%
% 第二级的标注写的是被启用的门控名，而不是把该事件称作“锁定”：
% 只有 'freq-state' 门控才是锁定判据的组成部分。
% 'center-touch' 门控是一条独立的码域测试，
% 把它的触发标成锁定会歪曲这条线实际代表的含义。
%
% 两个输入都是 NaN 安全的：从未触发的里程碑直接不画，
% 在非零频偏下用旧的 center-touch 门控时，第二级不触发才是常态。
% 配色刻意与这些坐标轴上已有的红色捕获标记区分开，
% 避免三条标记线混淆。
if isfinite(stage1Block)
    if labeled
        xline(stage1Block, '--', ...
            sprintf('stage-1 downshift (SNR>%gdB) block %g', ...
            snrThresholdDb, stage1Block), ...
            'Color', [0.00 0.55 0.25], 'LineWidth', 1.2, ...
            'LabelVerticalAlignment', 'bottom');
    else
        xline(stage1Block, '--', 'Color', [0.00 0.55 0.25], ...
            'LineWidth', 1.0);
    end
end
if isfinite(stage2Block)
    if labeled
        xline(stage2Block, '--', ...
            sprintf('stage-2 downshift (gate: %s) block %g', ...
            char(gateCriterion), stage2Block), ...
            'Color', [0.50 0.15 0.70], 'LineWidth', 1.2, ...
            'LabelVerticalAlignment', 'middle');
    else
        xline(stage2Block, '--', 'Color', [0.50 0.15 0.70], ...
            'LineWidth', 1.0);
    end
end
end
