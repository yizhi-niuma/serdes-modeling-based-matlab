function result = cdr_dlev_cdrffe_sslms_v4(varargin)
%CDR_DLEV_CDRFFE_SSLMS_V4 用 cdr_top 驱动 CDR+dlev+CDR FFE 验证。
%   本脚本只负责缓存读取、TI ADC 采样、起始相位扫描、trace 收集、统计、
%   绘图与结果落盘。所有 code 域 CDR DSP 交易由 cdr_top(config) 完成。

thisFile = mfilename('fullpath');
testDir = fileparts(fileparts(fileparts(thisFile)));
addpath(testDir);
paths = setup_cdr_dlev_cdrffe_paths();
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

analysisStartUi = 512;
analysisNumUi = options.AnalysisNumUi;
adcBlockUi = 64;
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

% 离线响应仅用于初始化选项、真值统计和结果绘图，不参与在线 DSP 交易。
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
        error('cdr_dlev_cdrffe_sslms_v4:InvalidFfeInitMode', ...
            'FfeInitMode must be ''planA'' or ''planB''.');
end

baseUi = 256;
uiGuard = 192;
maxFirstUi = analysisNumUi - adcBlockUi - uiGuard;
numBlocks = floor((maxFirstUi - baseUi) / adcBlockUi);
assert(numBlocks > 60, 'The analysis segment is too short for the loop run.');
if isempty(options.StartPhaseList)
    startPhaseList = 0:options.StartPhaseStep:samplePerSymbol - 1;
else
    startPhaseList = double(options.StartPhaseList(:).');
end
numStartPhase = numel(startPhaseList);

phaseCodeTrace = zeros(numStartPhase, numBlocks);
uiSlipTrace = zeros(numStartPhase, numBlocks);
timingErrorTrace = zeros(numStartPhase, numBlocks);
deltaCodeTrace = zeros(numStartPhase, numBlocks);
% 环路滤波器亚码连续量。整数 PI code 会把亚码运动藏起来，这四条用于区分
% "真抖动(围绕 0 变号)" 与 "缓慢漂移(持续非零直流速度)"。
loopControlTrace = zeros(numStartPhase, numBlocks);
loopFrequencyTrace = zeros(numStartPhase, numBlocks);
loopCodeResidueTrace = zeros(numStartPhase, numBlocks);
loopPendingCodeTrace = zeros(numStartPhase, numBlocks);
unwrappedPhaseTrace = zeros(numStartPhase, numBlocks);
edgeCountTrace = zeros(numStartPhase, numBlocks);
dlevInnerTrace = zeros(numStartPhase, numBlocks);
dlevOuterTrace = zeros(numStartPhase, numBlocks);
dlevThresholdTrace = zeros(numStartPhase, numBlocks);
ffeCoeffTrace = zeros(numStartPhase, numBlocks, cdrFfeTapCount);
ffeRawDeltaTrace = nan(numStartPhase, numBlocks, cdrFfeTapCount);
ffeProposedCoefficientTrace = nan(numStartPhase, numBlocks, cdrFfeTapCount);
ffeAppliedDeltaTrace = zeros(numStartPhase, numBlocks, cdrFfeTapCount);
ffeAdaptationCalculatedTrace = false(numStartPhase, numBlocks);
ffeWriteAppliedTrace = false(numStartPhase, numBlocks);
ffeFrozenTrace = false(numStartPhase, numBlocks);
ffeFreezeBlock = nan(1, numStartPhase);
ffeFreezeCenterUnwrapped = nan(1, numStartPhase);
ffeFreezeCenterWrapped = nan(1, numStartPhase);
ffeFreezeModeOccurrences = nan(1, numStartPhase);
ffeFreezeEventCount = nan(1, numStartPhase);
ffeFreezeResetCount = nan(1, numStartPhase);
ffeFrozenCoefficients = nan(numStartPhase, cdrFfeTapCount);
ffeFreezeState = cell(1, numStartPhase);
lockedPhaseCode = nan(1, numStartPhase);
lockedFlag = false(1, numStartPhase);
piCenterDiagnostics = cell(1, numStartPhase);
phaseSettleStd = nan(1, numStartPhase);

[~, histogramPhaseIndex] = min(abs(startPhaseList - referencePhase));
histogramTargetSamples = 2048;
histogramOutputHistory = [];
settleBlocks = 30;
piLockWindowBlocks = 2000;
piLockMinEvents = 51;
piLockBandHalfWidth = 3;
dlevSettleStdTolerance = 1.0;
ffeSettleStdTolerance = 0.01;

for startIndex = 1:numStartPhase
    startPhase = startPhaseList(startIndex);
    cfg = cdr_top.defaultConfig();
    cfg.BlockSize = adcBlockUi;
    cfg.SamplesPerSymbol = samplePerSymbol;
    cfg.Detector = 'mmpd';
    cfg.TransitionFilter = true;
    cfg.PdPolarity = options.Polarity;
    cfg.VoterMode = 'mean';
    cfg.VoterDenominator = 'auto';
    cfg.Kp = options.Kp;
    cfg.Ki = options.Ki;
    cfg.FrequencyLimit = 4;
    cfg.MaxDeltaCode = options.MaxDeltaCode;
    cfg.PiNumBit = 7;
    cfg.PiNonideal = 'ideal';
    cfg.PiInitialCode = startPhase;
    cfg.DlevInnerInit = options.DlevInnerInit;
    cfg.DlevOuterInit = options.DlevOuterInit;
    cfg.DlevPolarity = options.DlevPolarity;
    cfg.DlevStepSize = options.StepSize;
    cfg.DlevStepSizeSettle = options.StepSizeSettle;
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
    % 门控判据现在只有 freq-state(center-touch 已于 2026-09-28 从 cdr_top
    % 删除)。v4 是 0 ppm，期望环路频率态为 0；沿用 ppm 套件 0-ppm 情形相同
    % 的窗口/容差。上面的 FfeGateMin* 只用于构造 loop_monitor 里保留但休眠
    % 的 center-touch 机制(供旧 MAT 离线回放)，不再参与 v4 的冻结判定。
    cfg.FfeGateFreqWindowBlocks = min(options.FfeFreezeWindowBlocks, numBlocks);
    cfg.FfeGateFreqExpectedRate = 0;
    cfg.FfeGateFreqMeanHalfDiffTol = options.FreqMeanHalfDiffTol;
    cfg.FfeGateFreqStdTol = options.FreqStdTol;
    cfg.FfeGateFreqRateTol = options.FreqRateTol;
    cfg.FfeGateFreqMinBlock = 1;
    top = cdr_top(cfg);

    adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
        adcResolutionBits, adcSarPerTah, samplePerSymbol);
    adcModel.setInputMargin(0);

    for sampleBlockIndex = 1:numBlocks + 1
        if sampleBlockIndex <= numBlocks
            [sampleCodeWrapped, sampleUiSlip] = top.getSamplingPhase();
            firstUi = baseUi + (sampleBlockIndex - 1) * adcBlockUi + ...
                sampleUiSlip;
            blockStart = firstUi * samplePerSymbol + sampleCodeWrapped + 1;
            blockStop = blockStart + nominalBlockLength - 1;
            assert(blockStart >= 1 && blockStop <= numel(ctleSegment), ...
                'PI slip drove the sampling window off the cached segment.');
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
            loopCodeResidueTrace(startIndex, blockIndex) = out.LoopCodeResidue;
            loopPendingCodeTrace(startIndex, blockIndex) = out.LoopPendingCode;
            unwrappedPhaseTrace(startIndex, blockIndex) = out.UnwrappedCode;
            edgeCountTrace(startIndex, blockIndex) = sum(out.ValidTransition);
            dlevInnerTrace(startIndex, blockIndex) = out.DlevInner;
            dlevOuterTrace(startIndex, blockIndex) = out.DlevOuter;
            dlevThresholdTrace(startIndex, blockIndex) = out.DlevThreshold;
            ffeCoeffTrace(startIndex, blockIndex, :) = ...
                reshape(out.FfeCoefficients, 1, 1, cdrFfeTapCount);
            ffeRawDeltaTrace(startIndex, blockIndex, :) = ...
                reshape(out.FfeRawDelta, 1, 1, cdrFfeTapCount);
            ffeProposedCoefficientTrace(startIndex, blockIndex, :) = ...
                reshape(out.FfeProposedCoefficients, 1, 1, cdrFfeTapCount);
            ffeAppliedDeltaTrace(startIndex, blockIndex, :) = ...
                reshape(out.FfeAppliedDelta, 1, 1, cdrFfeTapCount);
            ffeAdaptationCalculatedTrace(startIndex, blockIndex) = ...
                out.FfeAdaptationCalculated;
            ffeWriteAppliedTrace(startIndex, blockIndex) = out.FfeWriteApplied;
            ffeFrozenTrace(startIndex, blockIndex) = out.GateEngaged;
            if startIndex == histogramPhaseIndex && ...
                    out.FfeAdaptationCalculated
                histogramOutputHistory = ...
                    [histogramOutputHistory, out.FfeOutput]; %#ok<AGROW>
            end
        end
    end

    topState = top.getState();
    freezeState = topState.Monitor;
    ffeFreezeState{startIndex} = freezeState;
    if freezeState.FreqGateDone
        ffeFreezeBlock(startIndex) = freezeState.FreqGateBlock;
        % freq-state 门控没有"模式中心"，用冻结当块的 tracked eye 相位作为
        % 记录中心(供眼图标注)。ModeOccurrences/EventCount/ResetCount 是
        % center-touch 专有计数，freq-state 下退役为 NaN。
        centerUnwrapped = unwrappedPhaseTrace(startIndex, ...
            freezeState.FreqGateBlock);
        ffeFreezeCenterUnwrapped(startIndex) = centerUnwrapped;
        ffeFreezeCenterWrapped(startIndex) = ...
            mod(centerUnwrapped, samplePerSymbol);
        ffeFrozenCoefficients(startIndex, :) = topState.GatedCoefficients;
    end

    settleWindow = unwrappedPhaseTrace(startIndex, end - settleBlocks + 1:end);
    phaseSettleStd(startIndex) = std(settleWindow);
    [lockedFlag(startIndex), lockedPhaseCode(startIndex), ...
        piCenterDiagnostics{startIndex}] = detect_pi_center_touch_lock( ...
        unwrappedPhaseTrace(startIndex, :), piLockWindowBlocks, ...
        piLockMinEvents, piLockBandHalfWidth, samplePerSymbol);

    centerDiag = piCenterDiagnostics{startIndex};
    fprintf(['Start phase %3d/%d: locked=%d, modal phase code=%g, ' ...
        'final events=%d, phase std=%.3f, final SS-MM error=%.4g, ' ...
        'dLev=[%.2f %.2f].\n'], startPhase, samplePerSymbol, ...
        lockedFlag(startIndex), lockedPhaseCode(startIndex), ...
        centerDiag.FinalCount, phaseSettleStd(startIndex), ...
        timingErrorTrace(startIndex, end), ...
        dlevInnerTrace(startIndex, end), dlevOuterTrace(startIndex, end));
end

centerUnwrapped = cellfun(@(diagnostic) diagnostic.CenterUnwrapped, ...
    piCenterDiagnostics);
[firstCaptureBlock, slowestIndex] = select_slowest_pi_capture( ...
    unwrappedPhaseTrace, centerUnwrapped, lockedFlag, ...
    piLockMinEvents, piLockBandHalfWidth);
selectionFlag = isfinite(slowestIndex);
selectedStartPhase = NaN;
selectedCaptureBlock = NaN;
if selectionFlag
    selectedStartPhase = startPhaseList(slowestIndex);
    selectedCaptureBlock = firstCaptureBlock(slowestIndex);
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
allPhaseLock = all(lockedFlag) && all(commonDistance <= 3);

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
ffeRegressorMatrix = buildPathRegressor(channelCtleSymbolPulse, ...
    samplePerSymbol, evalPhase, cdrFfeEvalOffset, cdrFfeTapOffset, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    laneToTimeOrder, nominalBlockLength, adcZeroCode);
ffeMeanOutputCursor = reshape(ffeRegressorMatrix * ffeCoeffMean(:), 1, []);
ffeMainRow = find(cdrFfeEvalOffset == 0, 1);
ffeMeanNormalizedCursor = ffeMeanOutputCursor / ffeMeanOutputCursor(ffeMainRow);
ffePre1Final = ffeMeanNormalizedCursor(cdrFfeEvalOffset == -1);
ffePost1Final = ffeMeanNormalizedCursor(cdrFfeEvalOffset == 1);
ffeConstraintHeld = abs(ffePre1Final) <= 0.02 && abs(ffePost1Final) <= 0.02;

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

resultDir = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms_v4');
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
resultMatPath = fullfile(resultDir, 'cdr_dlev_cdrffe_sslms_v4_result.mat');
loopDitherFigurePath = fullfile(resultDir, 'cdr_loop_dither_vs_drift.fig');

if options.SaveOutputs
    blockAxis = 1:numBlocks;
    % 绘图用派生量：选中相位的众数锁定码、FFE 门控标签、显示主光标行。
    selectedModalPhaseCode = NaN;
    if selectionFlag
        selectedModalPhaseCode = lockedPhaseCode(slowestIndex);
    end
    if strcmpi(char(options.FfeFreezeMode), 'freeze')
        ffeGateBlockWord = 'frozen';
    else
        ffeGateBlockWord = 'PVT-track';
    end
    displayMainRow = find(displayEvalOffset == 0, 1);
    ffeAdaptEnableMask = logical(options.FfeAdaptEnableMask);
    dlevInnerInit = options.DlevInnerInit;
    dlevOuterInit = options.DlevOuterInit;
    ffeInitModeLabel = lower(char(options.FfeInitMode));

    % 图 1：选中相位的相位收敛，附众数码/参考相位/首次捕获块/FFE 门控块标记。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
    if selectionFlag
        plot(blockAxis, phaseCodeTrace(slowestIndex, :), ...
            'Color', [0.10 0.40 0.80], 'LineWidth', 1.0);
        hold on;
        yline(selectedModalPhaseCode, 'k--', ...
            sprintf('selected modal code %d', selectedModalPhaseCode), ...
            'LineWidth', 1.2);
        yline(referencePhase, 'm:', ...
            sprintf('S-curve reference phase %d', referencePhase), ...
            'LineWidth', 1.1);
        xline(selectedCaptureBlock, 'r--', ...
            sprintf('first capture block %d', selectedCaptureBlock), ...
            'LineWidth', 1.2);
        if ffeFrozenTrace(slowestIndex, end)
            xline(ffeFreezeBlock(slowestIndex), '--', ...
                sprintf('FFE %s block %d', ffeGateBlockWord, ...
                ffeFreezeBlock(slowestIndex)), ...
                'Color', [0.1 0.6 0.2], 'LineWidth', 1.1, ...
                'LabelVerticalAlignment', 'bottom');
        end
        hold off;
        grid on;
        xlim([blockAxis(1) blockAxis(end)]);
        ylim([0 samplePerSymbol - 1]);
        xlabel('CDR Block Index (64 UI per block)');
        ylabel('PI Sampling Phase Code (wrapped, sample index)');
        title(sprintf(['Triple-loop CDR Phase Convergence: slowest first PI capture, ' ...
            'start phase %d, first capture block %d, Kp=%.3g, Ki=%.3g'], ...
            selectedStartPhase, selectedCaptureBlock, options.Kp, options.Ki));
    else
        axis off;
        text(0.5, 0.5, ['No finally locked start phase has a qualifying ' ...
            'first PI capture.'], 'Units', 'normalized', ...
            'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('Triple-loop CDR Phase Convergence: no eligible capture');
    end
    saveFigureResilient(fig, convergenceFigurePath); close(fig);

    % 图 2：锁定相位码 vs 起始相位，蓝圈通过、红叉失败、公共锁定码虚线。
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
            sprintf('common lock code %d', commonLockPhase), 'LineWidth', 1.2);
    end
    hold off;
    grid on;
    xlim([min(startPhaseList) - 0.5 max(startPhaseList) + 0.5]);
    xlabel('Initial Sampling Phase Code');
    ylabel('Modal PI code (last 2000 blocks)');
    title(sprintf(['Modal PI Code vs Start Phase (%d/%d locked, ' ...
        'all-phase lock = %d, spread = %g code)'], sum(lockedFlag), ...
        numStartPhase, allPhaseLock, phaseSpread));
    saveFigureResilient(fig, lockSummaryFigurePath); close(fig);

    % 图 3：选中相位的 dLev 收敛，附内外参考/初值电平线、首次捕获与门控块标记。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
    if selectionFlag
        plot(blockAxis, dlevOuterTrace(slowestIndex, :), ...
            'Color', [0.10 0.40 0.80], 'LineWidth', 1.0);
        hold on;
        plot(blockAxis, dlevInnerTrace(slowestIndex, :), ...
            'Color', [0.85 0.35 0.10], 'LineWidth', 1.0);
        yline(dlevOuterReference, 'r--', ...
            sprintf('outer ref %.2f', dlevOuterReference), 'LineWidth', 1.2);
        yline(dlevInnerReference, 'r:', ...
            sprintf('inner ref %.2f', dlevInnerReference), 'LineWidth', 1.2);
        yline(dlevOuterInit, 'k--', ...
            sprintf('outer init %.2f', dlevOuterInit), 'LineWidth', 1.0);
        yline(dlevInnerInit, 'k:', ...
            sprintf('inner init %.2f', dlevInnerInit), 'LineWidth', 1.0);
        xline(selectedCaptureBlock, 'r--', ...
            sprintf('PI first capture block %d', selectedCaptureBlock), ...
            'LineWidth', 1.2);
        if ffeFrozenTrace(slowestIndex, end)
            xline(ffeFreezeBlock(slowestIndex), '--', ...
                sprintf('FFE %s block %d', ffeGateBlockWord, ...
                ffeFreezeBlock(slowestIndex)), ...
                'Color', [0.1 0.6 0.2], 'LineWidth', 1.1, ...
                'LabelVerticalAlignment', 'bottom');
        end
        hold off;
        grid on;
        xlim([blockAxis(1) blockAxis(end)]);
        xlabel('CDR Block Index (64 UI per block)');
        ylabel('Adapted dLev (code domain)');
        title(sprintf(['dLev Trace at Slowest PI First-Capture Start: phase %d, ' ...
            'PI first capture block %d, mu=%.4g->%.4g'], ...
            selectedStartPhase, selectedCaptureBlock, options.StepSize, ...
            options.StepSizeSettle));
    else
        axis off;
        text(0.5, 0.5, ['No finally locked start phase has a qualifying ' ...
            'first PI capture.'], 'Units', 'normalized', ...
            'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('dLev Trace: no eligible PI capture');
    end
    saveFigureResilient(fig, dlevConvergenceFigurePath); close(fig);

    % 图 4：FFE 系数收敛，每个自由抽头一个子图，附离线参考/捕获/门控标记与 pre/post 命名。
    freeTapIndexList = find(ffeAdaptEnableMask);
    numFreeTap = numel(freeTapIndexList);
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 720]);
    if selectionFlag
        tiledLayout = tiledlayout(fig, numFreeTap, 1, ...
            'TileSpacing', 'compact', 'Padding', 'compact');
        for freeIdx = 1:numFreeTap
            tapIndex = freeTapIndexList(freeIdx);
            nexttile(tiledLayout);
            tapTrace = reshape(ffeCoeffTrace(slowestIndex, :, tapIndex), ...
                1, numBlocks);
            plot(blockAxis, tapTrace, 'Color', [0.10 0.40 0.80], 'LineWidth', 0.9);
            hold on;
            yline(cdrFfeCoefficients(tapIndex), 'k--', ...
                sprintf('offline %.4f', cdrFfeCoefficients(tapIndex)), ...
                'LineWidth', 1.1);
            xline(selectedCaptureBlock, 'r--', ...
                sprintf('PI capture %d', selectedCaptureBlock), 'LineWidth', 1.0);
            if ffeFrozenTrace(slowestIndex, end)
                xline(ffeFreezeBlock(slowestIndex), '--', ...
                    'Color', [0.1 0.6 0.2], 'LineWidth', 1.0);
            end
            hold off;
            grid on;
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
                title(tiledLayout, sprintf(['CDR FFE Trace at Slowest PI First-Capture ' ...
                    'Start: phase %d, PI first capture block %d, %s, mu=%.3g->%.3g'], ...
                    selectedStartPhase, selectedCaptureBlock, ffeInitModeLabel, ...
                    options.FfeStepSize, options.FfeStepSizeSettle));
            end
            if freeIdx == numFreeTap
                xlabel('CDR Block Index (64 UI per block)');
            end
        end
    else
        axis off;
        text(0.5, 0.5, ['No finally locked start phase has a qualifying ' ...
            'first PI capture.'], 'Units', 'normalized', ...
            'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('CDR FFE Trace: no eligible PI capture');
    end
    saveFigureResilient(fig, ffeConvergenceFigurePath); close(fig);

    % 图 5：收敛稳态 FFE 输出直方图，叠加离线参考电平（灰）与在线收敛 dlev 电平（红）。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 620]);
    ax = axes(fig);
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
    grid(ax, 'on');
    xlabel(ax, 'Converged CDR FFE Output (code domain)');
    ylabel(ax, 'Sample Count');
    title(ax, sprintf(['Converged CDR FFE Output Histogram ' ...
        '(start phase %d -> locked sampling phase code %d, %d samples = last blocks %d-%d)'], ...
        startPhaseList(histogramPhaseIndex), lockedPhaseCode(histogramPhaseIndex), ...
        numel(histogramSamples), ...
        numBlocks - round(numel(histogramSamples) / adcBlockUi) + 1, numBlocks));
    saveFigureResilient(fig, ffeHistogramFigurePath); close(fig);

    % 图 6：channel->CTLE->ADC->CDR FFE 总通路单位 UI 响应，标注每个游标数值与主光标。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 620]);
    stemHandle = stem(displayEvalOffset, displayNormalizedCursor, 'filled', ...
        'LineWidth', 1.3, 'Color', [0.2 0.4 0.8]);
    stemHandle.MarkerSize = 6;
    hold on;
    stem(0, displayNormalizedCursor(displayMainRow), 'filled', ...
        'LineWidth', 1.6, 'Color', [0.85 0.2 0.2], 'MarkerSize', 8);
    yline(0, 'k--', 'pre1/post1 target 0 (SS-LMS ISI-null)', 'LineWidth', 1.0);
    for cursorIdx = 1:numel(displayEvalOffset)
        text(displayEvalOffset(cursorIdx), displayNormalizedCursor(cursorIdx), ...
            sprintf('%.3f', displayNormalizedCursor(cursorIdx)), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontSize', 7);
    end
    hold off;
    grid on;
    xlim([displayEvalOffset(1) - 0.5, displayEvalOffset(end) + 0.5]);
    xticks(displayEvalOffset);
    xlabel('Cursor Offset (UI, 0 = main)');
    ylabel('Normalized Total-Path Response (main = 1)');
    title(sprintf(['Total-Path Unit-UI Response (channel->CTLE->ADC->CDR FFE): ' ...
        '3 pre + 1 main + 8 post, %s | evaluated @ lock phase %d (S-curve ref %d)'], ...
        ffeInitModeLabel, evalPhase, referencePhase));
    saveFigureResilient(fig, totalPathResponseFigurePath); close(fig);

    % 图 7：抖动 vs 漂移诊断。整数 PI code 会把亚码运动藏起来，这里画环路滤波器
    % 量化前的连续量：LoopControl 是相位速度需求(code/block)，围绕 0 变号 = 真抖动，
    % 持续非零直流 = 缓慢漂移；FrequencyState 的稳态值就是漂移速度估计。
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 780]);
    if selectionFlag
        ditherLayout = tiledlayout(fig, 3, 1, ...
            'TileSpacing', 'compact', 'Padding', 'compact');
        tailWindow = max(1, numBlocks - 2000 + 1):numBlocks;
        ctrl = loopControlTrace(slowestIndex, :);
        freq = loopFrequencyTrace(slowestIndex, :);
        resid = loopCodeResidueTrace(slowestIndex, :);
        tailDelta = deltaCodeTrace(slowestIndex, tailWindow);
        nonZeroDelta = tailDelta(tailDelta ~= 0);
        signFlipRatio = NaN;
        if numel(nonZeroDelta) > 1
            signFlipRatio = sum(diff(sign(nonZeroDelta)) ~= 0) / ...
                (numel(nonZeroDelta) - 1);
        end
        netDriftUi = (unwrappedPhaseTrace(slowestIndex, tailWindow(end)) - ...
            unwrappedPhaseTrace(slowestIndex, tailWindow(1))) / samplePerSymbol;
        tailMeanControl = mean(ctrl(tailWindow));

        nexttile(ditherLayout);
        plot(blockAxis, ctrl, 'Color', [0.10 0.40 0.80], 'LineWidth', 0.7);
        hold on;
        yline(0, 'k--', 'LineWidth', 1.0);
        yline(tailMeanControl, 'r--', ...
            sprintf('tail mean %.3g code/block', tailMeanControl), ...
            'LineWidth', 1.2);
        xline(selectedCaptureBlock, 'r--', 'LineWidth', 1.0);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylabel('LoopControl (code/block)');
        title(ditherLayout, sprintf(['Loop dither vs drift, start phase %d | ' ...
            'tail mean velocity %.3g code/block, sign-flip %.0f%%, net drift %.4f UI'], ...
            selectedStartPhase, tailMeanControl, 100 * signFlipRatio, netDriftUi));

        nexttile(ditherLayout);
        plot(blockAxis, freq, 'Color', [0.85 0.35 0.10], 'LineWidth', 0.9);
        hold on;
        yline(0, 'k--', 'LineWidth', 1.0);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylabel('FrequencyState (code/block)');

        nexttile(ditherLayout);
        plot(blockAxis, resid, 'Color', [0.2 0.6 0.3], 'LineWidth', 0.7);
        hold on;
        yline(0, 'k--', 'LineWidth', 1.0);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylim([-1 1]);
        ylabel('CodeResidue (sub-code)');
        xlabel('CDR Block Index (64 UI per block)');
    else
        axis off;
        text(0.5, 0.5, ['No finally locked start phase has a qualifying ' ...
            'first PI capture.'], 'Units', 'normalized', ...
            'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('Loop dither vs drift diagnostic: no eligible capture');
    end
    saveFigureResilient(fig, loopDitherFigurePath); close(fig);
end

result = struct();
result.CachePath = cachePath;
result.AnalysisStartUi = analysisStartUi;
result.AnalysisNumUi = analysisNumUi;
result.SamplePerSymbol = samplePerSymbol;
result.ReferencePhase = referencePhase;
result.EvalPhase = evalPhase;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.CdrFfeTapOffset = cdrFfeTapOffset;
result.CdrFfeMainTapIndex = cdrFfeMainTapIndex;
result.FfeCostMode = 'sslms_ssmmpd';
result.FfeInitMode = lower(char(options.FfeInitMode));
result.FfeBiasScale = options.FfeBiasScale;
result.FfeInitCoefficients = ffeInitCoefficients;
result.FfeStepSize = options.FfeStepSize;
result.FfeStepSizeSettle = options.FfeStepSizeSettle;
result.FfeAdaptEnableMask = logical(options.FfeAdaptEnableMask);
result.LevelCenter = levelCenter;
result.DlevInnerReference = dlevInnerReference;
result.DlevOuterReference = dlevOuterReference;
result.DlevInnerInit = options.DlevInnerInit;
result.DlevOuterInit = options.DlevOuterInit;
result.DlevOuterNominal = options.DlevOuterInit;
result.PdType = 'ss-mmpd';
result.PdOffset = options.PdOffset;
result.LoopKp = options.Kp;
result.LoopKi = options.Ki;
result.LoopMaxDeltaCode = options.MaxDeltaCode;
result.LoopFrequencyLimit = 4;
result.PdPolarity = options.Polarity;
result.DlevStepSize = options.StepSize;
result.DlevStepSizeSettle = options.StepSizeSettle;
result.DlevPolarity = options.DlevPolarity;
result.PiNumBit = 7;
result.BaseUi = baseUi;
result.NumBlocks = numBlocks;
result.StartPhaseList = startPhaseList;
result.PhaseCodeTrace = phaseCodeTrace;
result.UiSlipTrace = uiSlipTrace;
result.UnwrappedPhaseTrace = unwrappedPhaseTrace;
result.TimingErrorTrace = timingErrorTrace;
result.DeltaCodeTrace = deltaCodeTrace;
result.LoopControlTrace = loopControlTrace;
result.LoopFrequencyStateTrace = loopFrequencyTrace;
result.LoopCodeResidueTrace = loopCodeResidueTrace;
result.LoopPendingCodeTrace = loopPendingCodeTrace;
result.EdgeCountTrace = edgeCountTrace;
result.DlevInnerTrace = dlevInnerTrace;
result.DlevOuterTrace = dlevOuterTrace;
result.DlevThresholdTrace = dlevThresholdTrace;
result.FfeCoeffTrace = ffeCoeffTrace;
result.FfeFreezeEnable = logical(options.FfeFreezeEnable);
result.FfeFreezeMinModeOccurrences = options.FfeFreezeMinModeOccurrences;
result.FfeFreezeMinEvents = options.FfeFreezeMinEvents;
result.FfeFreezeBandHalfWidth = options.FfeFreezeBandHalfWidth;
result.FfeFreezeMode = lower(char(options.FfeFreezeMode));
result.FfeStepSizePvtTrack = options.FfeStepSizePvtTrack;
result.FfeFreezeStartBlock = 1;
result.FfeFrozenFlag = ffeFrozenTrace(:, end).';
result.FfeFreezeBlock = ffeFreezeBlock;
result.FfeFreezeCenterUnwrapped = ffeFreezeCenterUnwrapped;
result.FfeFreezeCenterWrapped = ffeFreezeCenterWrapped;
result.FfeFreezeModeOccurrences = ffeFreezeModeOccurrences;
result.FfeFreezeEventCount = ffeFreezeEventCount;
result.FfeFreezeResetCount = ffeFreezeResetCount;
result.FfeFrozenCoefficients = ffeFrozenCoefficients;
result.FfeFreezeState = [ffeFreezeState{:}];
result.FfeRawDeltaTrace = ffeRawDeltaTrace;
result.FfeProposedCoefficientTrace = ffeProposedCoefficientTrace;
result.FfeAppliedDeltaTrace = ffeAppliedDeltaTrace;
result.FfeAdaptationCalculatedTrace = ffeAdaptationCalculatedTrace;
result.FfeWriteAppliedTrace = ffeWriteAppliedTrace;
result.FfeFrozenTrace = ffeFrozenTrace;
result.SettleBlocks = settleBlocks;
result.LockCriterion = ['last-2000-block fixed unwrapped modal center; ' ...
    'all samples within center +/-3'];
result.LockWindowBlocks = piLockWindowBlocks;
result.LockMinEvents = piLockMinEvents;
result.LockBandHalfWidth = piLockBandHalfWidth;
result.PiCenterDiagnostics = [piCenterDiagnostics{:}];
result.PiCenterFinalCount = [result.PiCenterDiagnostics.FinalCount];
result.PiCenterTotalEvents = [result.PiCenterDiagnostics.TotalEvents];
result.PiCenterOutOfBandCount = [result.PiCenterDiagnostics.OutOfBandCount];
result.PiCenterOnsetBlock = [result.PiCenterDiagnostics.OnsetBlock];
result.FirstCaptureBlock = firstCaptureBlock;
result.SlowestCapturePhaseIndex = slowestIndex;
result.SlowestCaptureStartPhase = selectedStartPhase;
result.SlowestFirstCaptureBlock = selectedCaptureBlock;
result.ConvergencePlotPhaseIndex = slowestIndex;
result.ConvergencePlotStartPhase = selectedStartPhase;
result.PhaseSettleStd = phaseSettleStd;
result.DlevSettleStdTolerance = dlevSettleStdTolerance;
result.FfeSettleStdTolerance = ffeSettleStdTolerance;
result.LockedPhaseCode = lockedPhaseCode;
result.LockedFlag = lockedFlag;
result.CommonLockPhase = commonLockPhase;
result.PhaseSpread = phaseSpread;
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
result.FfeMeanNormalizedCursor = ffeMeanNormalizedCursor;
result.DisplayEvalOffset = displayEvalOffset;
result.DisplayNormalizedCursor = displayNormalizedCursor;
result.FfePre1Final = ffePre1Final;
result.FfePost1Final = ffePost1Final;
result.FfeConstraintHeld = ffeConstraintHeld;
result.HistogramPhaseIndex = histogramPhaseIndex;
result.HistogramSamples = histogramSamples;
result.ConvergenceFigurePath = convergenceFigurePath;
result.TimingErrorFigurePath = fullfile(resultDir, 'cdr_block_timing_error.fig');
result.LockSummaryFigurePath = lockSummaryFigurePath;
result.DlevConvergenceFigurePath = dlevConvergenceFigurePath;
result.FfeConvergenceFigurePath = ffeConvergenceFigurePath;
result.FfeHistogramFigurePath = ffeHistogramFigurePath;
result.TotalPathResponseFigurePath = totalPathResponseFigurePath;
result.LoopDitherFigurePath = loopDitherFigurePath;
result.EyeDiagramEnable = logical(options.EyeDiagramEnable);
result.EyeDiagramUiCountRequested = options.EyeDiagramUiCount;

freezeEye = struct('Valid', false, 'Reason', 'Eye diagrams disabled.');
finalEye = struct('Valid', false, 'Reason', 'Eye diagrams disabled.');
eyeMeta = struct();
eyeFigurePaths = struct('Freeze', '', 'Final', '', 'Comparison', '');
if options.EyeDiagramEnable
    if selectionFlag
        eyeInfo = struct();
        eyeInfo.SelectedStartPhase = selectedStartPhase;
        eyeInfo.SamplesPerUi = samplePerSymbol;
        eyeInfo.NumBlocks = numBlocks;
        eyeInfo.AdcBlockUi = adcBlockUi;
        eyeInfo.BaseUi = baseUi;
        eyeInfo.AnalysisStartUi = analysisStartUi;
        eyeInfo.UiSlipTrace = uiSlipTrace(slowestIndex, :);
        eyeInfo.PreTapCount = cdrFfePreTapCount;
        eyeInfo.AdcBits = adcResolutionBits;
        eyeInfo.AdcRange = [-adcFullRange adcFullRange];
        eyeInfo.FinalCoefficients = ffeFinalCoefficients(slowestIndex, :);
        eyeInfo.Frozen = logical(ffeFrozenTrace(slowestIndex, end));
        eyeInfo.FreezeBlock = ffeFreezeBlock(slowestIndex);
        eyeInfo.FrozenCoefficients = ffeFrozenCoefficients(slowestIndex, :);
        eyeInfo.FreezeCenterCode = ffeFreezeCenterWrapped(slowestIndex);
        eyeInfo.FinalLockCode = lockedPhaseCode(slowestIndex);
        [freezeEye, finalEye, eyeMeta] = build_cdr_ffe_eye_pair( ...
            ctleSegment, eyeInfo, options.EyeDiagramUiCount);
    else
        freezeEye = struct('Valid', false, ...
            'Reason', 'No finally locked start selected.');
        finalEye = freezeEye;
        eyeMeta = struct('SelectedStartPhase', NaN);
    end
    eyePlotConfig = struct('ResultDir', resultDir, ...
        'SelectedStartPhase', selectedStartPhase, ...
        'FreezeBlock', NaN, 'FreezeCenterCode', NaN, ...
        'FinalLockCode', NaN, ...
        'UiCountRequested', options.EyeDiagramUiCount, ...
        'SaveOutputs', options.SaveOutputs);
    if selectionFlag
        eyePlotConfig.FreezeBlock = ffeFreezeBlock(slowestIndex);
        eyePlotConfig.FreezeCenterCode = ffeFreezeCenterWrapped(slowestIndex);
        eyePlotConfig.FinalLockCode = lockedPhaseCode(slowestIndex);
    end
    eyeFigurePaths = plot_cdr_ffe_eyes(freezeEye, finalEye, eyePlotConfig);
end
result.EyeDiagramFreeze = freezeEye;
result.EyeDiagramFinal = finalEye;
result.EyeDiagramMetadata = eyeMeta;
result.FreezeFigurePath = eyeFigurePaths.Freeze;
result.FinalFigurePath = eyeFigurePaths.Final;
result.ComparisonFigurePath = eyeFigurePaths.Comparison;
result.ResultMatPath = resultMatPath;
result.EyeDiagramFreezeFigurePath = eyeFigurePaths.Freeze;
result.EyeDiagramFinalFigurePath = eyeFigurePaths.Final;
result.EyeDiagramComparisonFigurePath = eyeFigurePaths.Comparison;
result.FirstCaptureSummaryPath = fullfile(resultDir, 'first_capture_summary.csv');
result.FfeFreezeSummaryPath = fullfile(resultDir, 'ffe_freeze_summary.csv');

if options.SaveOutputs
    writetable(table(result.StartPhaseList(:), result.LockedPhaseCode(:), ...
        result.LockedFlag(:), result.FirstCaptureBlock(:), ...
        result.PiCenterFinalCount(:), 'VariableNames', ...
        {'StartPhase', 'TailMode', 'FinalLocked', 'FirstCaptureBlock', ...
        'FinalWindowEventCount'}), result.FirstCaptureSummaryPath);
    writetable(table(result.StartPhaseList(:), result.FfeFreezeBlock(:), ...
        result.FfeFreezeCenterWrapped(:), result.FfeFreezeModeOccurrences(:), ...
        result.FfeFreezeEventCount(:), result.FfeFreezeResetCount(:), ...
        result.LockedPhaseCode(:), result.LockedFlag(:), ...
        result.PiCenterFinalCount(:), result.FirstCaptureBlock(:), ...
        'VariableNames', {'StartPhase', 'FreezeBlock', 'FreezeCenter', ...
        'CenterOccurrences', 'FreezeEvents', 'SearchResets', 'FinalMode', ...
        'FinalLocked', 'FinalWindowEvents', 'FirstCaptureBlock'}), ...
        result.FfeFreezeSummaryPath);
    save(resultMatPath, 'result', '-v7.3');
end

fprintf('v4 completed: %d/%d start phases locked.\n', ...
    sum(lockedFlag), numStartPhase);
end

function options = parseLoopOptions(varargin)
defaults = struct();
defaults.Kp = 8.0;
defaults.Ki = 0.03;
defaults.PdOffset = -0.05;
defaults.MaxDeltaCode = 1;
defaults.Polarity = 1;
defaults.StepSize = 0.5;
defaults.StepSizeSettle = 0.1;
defaults.DlevPolarity = 1;
defaults.DlevOuterInit = 48;
defaults.DlevInnerInit = 16;
defaults.FfeStepSize = 0.004;
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
% freq-state 冻结门控(0 ppm 期望速率 0)的窗口与平坦性容差，取值与 ppm 套件
% 0-ppm 情形一致。FfeFreezeMin*/BandHalfWidth 只是 loop_monitor 里休眠的
% center-touch 机制的构造参数，不再决定 v4 的冻结。
defaults.FfeFreezeWindowBlocks = 2000;
defaults.FreqMeanHalfDiffTol = 0.03;
defaults.FreqStdTol = 0.08;
defaults.FreqRateTol = 0.12;
defaults.EyeDiagramEnable = true;
defaults.EyeDiagramUiCount = 2048;
defaults.SaveOutputs = true;
defaults.ResultDir = '';
defaults.StartPhaseList = [];
defaults.StartPhaseStep = 16;
defaults.CosimDir = 'channel_ctle_cosim_prbs22';
defaults.NumBlock = 15000;
defaults.AnalysisNumUi = defaults.NumBlock * 64 + 512;
options = defaults;
providedNames = {};
if numel(varargin) == 1 && isstruct(varargin{1})
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
gaveNumBlock = any(strcmp('NumBlock', providedNames));
gaveAnalysisNumUi = any(strcmp('AnalysisNumUi', providedNames));
if gaveNumBlock && ~gaveAnalysisNumUi
    options.AnalysisNumUi = options.NumBlock * 64 + 512;
elseif gaveNumBlock && gaveAnalysisNumUi
    assert(options.AnalysisNumUi == options.NumBlock * 64 + 512, ...
        'NumBlock and AnalysisNumUi are inconsistent.');
end
end

function validateOptions(options)
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
validateattributes(options.SaveOutputs, {'numeric', 'logical'}, ...
    {'scalar', 'real', 'finite'});
validateattributes(options.EyeDiagramEnable, {'numeric', 'logical'}, ...
    {'scalar', 'real', 'finite'});
assert(any(double(options.SaveOutputs) == [0 1]), ...
    'SaveOutputs must be logical or numeric 0/1.');
assert(any(double(options.EyeDiagramEnable) == [0 1]), ...
    'EyeDiagramEnable must be logical or numeric 0/1.');
assert(any(strcmpi(char(options.FfeFreezeMode), {'freeze', 'pvt-track'})), ...
    'FfeFreezeMode must be freeze or pvt-track.');
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
%ADDDLEVHISTOGRAMREFERENCELINES 在直方图坐标轴上画离线参考电平与收敛 dlev 电平。
%   灰虚线为四个离线参考电平中心 levelCenter(1:4);红虚线为收敛后真实 dlev
%   (观测相位)的内外正负电平中心。返回首条灰线与首条红线的句柄供图例使用。
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
            warning('cdr_dlev_cdrffe_sslms_v4:FigureSaveFailed', ...
                'Could not save "%s": %s', filePath, saveError.message);
            return;
        end
        pause(0.5);
    end
end
end
