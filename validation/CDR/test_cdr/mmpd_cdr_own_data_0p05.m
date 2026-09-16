function result = mmpd_cdr_own_data_0p05(varargin)
%MMPD_CDR_OWN_DATA Run a real-time CDR closed loop on cached CTLE data.
%   This script reuses the offline MMPD S-curve receiver chain (TI ADC,
%   CDR FFE, PAM4 slicer and the classic Mueller-Muller timing error) but,
%   instead of sweeping a fixed phase, it closes the loop through the real
%   cdr_loop PI filter and cdr_pi phase interpolator. A block of 64 UI
%   produces one mean MM timing error, which drives one PI code update, so
%   the sampling phase tracks toward lock exactly like the hardware CDR.
%
%   The verification target is all-phase lock: starting from many initial
%   phases (0, 4, 8, ... every 4 codes), the loop must converge to the same
%   steady sampling phase. Only a subset of start phases is exercised; the
%   goal is loop convergence, not a dense S-curve.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
afeValidationDir = fileparts(testDir);
validationDir = fileparts(afeValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

cachePath = fullfile(testDir, 'result', 'channel_ctle_cosim', ...
    'channel_ctle.mat');
assert(isfile(cachePath), ...
    'Run test_channel_ctle_cosim first to generate channel_ctle.mat.');
cacheFile = matfile(cachePath);
samplePerSymbol = double(cacheFile.samplePerSymbol);
numCachedSymbols = double(cacheFile.numSymbols);
assert(samplePerSymbol == 128, ...
    'The cached CTLE waveform must use 128 samples/UI.');
assert(logical(cacheFile.isCompletePrbs20Period), ...
    'The cached CTLE waveform is not a complete PRBS20 period.');

analysisStartUi = 512;
analysisNumUi = 8192 * 2 ;
adcBlockUi = 64;
assert(mod(analysisNumUi, adcBlockUi) == 0, ...
    'The fixed analysis segment must contain complete 64-UI blocks.');
assert(analysisStartUi + analysisNumUi <= numCachedSymbols, ...
    'The fixed 8192-UI analysis segment exceeds the CTLE cache.');

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
cdrFfeEvalOffset = -3:6;
[laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol);

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
totalUnitUiResponseNormalized = cdrFfeDesign.NormalizedCursor;
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == -1) - 0.05) < 1e-6);
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 0) - 1) < 1e-12);
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 1) - 0.05) < 1e-6);

% The slicer is calibrated once, at the reference phase, exactly as the
% offline S-curve script does. The same code->amplitude map is then reused
% throughout the closed-loop run so the receiver has a fixed slicer.
referenceOutput = processOnePhase(ctleSegment, referencePhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, ...
    adcFullRange, adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, adcBlockUi);
levelCenter = estimatePam4Centers(referenceOutput);
symbolLevels = [-3 -1 1 3];
codeToSymbol = polyfit(levelCenter, symbolLevels, 1);

% --- CDR closed-loop configuration -----------------------------------
% cdr_pi is used with NumBit = 7 so that 128 PI codes map one-to-one onto
% the 128 samples per UI. The ideal (linear) phase table is selected so
% that 1 PI code equals exactly 1 sample of sampling-phase movement, which
% keeps the loop analysis identical to the sample-index S-curve.
piNumBit = 7;
piCodeCount = 2^piNumBit;
assert(piCodeCount == samplePerSymbol, ...
    'The PI code count must equal the samples per UI.');

% Loop-filter gains. Kp/Ki were tuned so that every start phase acquires
% and holds lock well within the available block budget without ringing.
options = parseLoopOptions(varargin{:});
loopKp = options.Kp;
loopKi = options.Ki;
loopMaxDeltaCode = options.MaxDeltaCode;
loopFrequencyLimit = 4;
pdPolarity = options.Polarity;
saveOutputs = options.SaveOutputs;

% Block schedule. A guard band of whole UI is kept on both sides of the
% analysis segment so that PI UI-slip during acquisition never samples off
% the cached waveform.
baseUi = 256;
uiGuard = 192;
maxFirstUi = analysisNumUi - adcBlockUi - uiGuard;
numBlocks = floor((maxFirstUi - baseUi) / adcBlockUi);
numBlocks = min(numBlocks, 240);
assert(numBlocks > 60, 'The analysis segment is too short for the loop run.');

startPhaseList = 0:4:samplePerSymbol - 1;
numStartPhase = numel(startPhaseList);

phaseCodeTrace = zeros(numStartPhase, numBlocks);
uiSlipTrace = zeros(numStartPhase, numBlocks);
timingErrorTrace = zeros(numStartPhase, numBlocks);
deltaCodeTrace = zeros(numStartPhase, numBlocks);
unwrappedPhaseTrace = zeros(numStartPhase, numBlocks);
edgeCountTrace = zeros(numStartPhase, numBlocks);
lockedPhaseCode = zeros(1, numStartPhase);
lockedFlag = false(1, numStartPhase);

settleBlocks = 30;
% On a static, zero-ppm cached waveform a bang-bang MMPD loop cannot sit
% perfectly still: in steady state it limit-cycles by +/-1 to +/-2 sampling
% codes around the true crossing. The lock test therefore accepts a
% settle-window std of up to 1.5 codes (the intrinsic dither floor) and an
% ensemble spread of up to 2 codes, rather than demanding a frozen code.
lockStdTolerance = 1.5;

for startIndex = 1:numStartPhase
    startPhase = startPhaseList(startIndex);

    phaseInterpolator = cdr_pi(piNumBit, samplePerSymbol);
    phaseInterpolator.resetNonideal();
    phaseInterpolator.setCode(startPhase);
    loopFilter = cdr_loop(loopKp, loopKi, ...
        -loopFrequencyLimit, loopFrequencyLimit, loopMaxDeltaCode);
    loopFilter.resetState();

    for blockIndex = 1:numBlocks
        codeWrapped = phaseInterpolator.CodeWrapped;
        uiSlip = phaseInterpolator.UiSlip;
        firstUi = baseUi + (blockIndex - 1) * adcBlockUi + uiSlip;
        blockStart = firstUi * samplePerSymbol + codeWrapped + 1;
        blockStop = blockStart + nominalBlockLength - 1;
        assert(blockStart >= 1 && blockStop <= numel(ctleSegment), ...
            'PI slip drove the sampling window off the cached segment.');
        blockWaveform = ctleSegment(blockStart:blockStop);

        ffeOutput = processOneBlock(blockWaveform, samplePerSymbol, ...
            adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
            adcZeroCode, laneToTimeOrder, cdrFfeCoefficients, ...
            cdrFfePreTapCount);
        sampledAmplitude = polyval(codeToSymbol, ffeOutput);
        decisionAmplitude = slicePam4Amplitude(sampledAmplitude, symbolLevels);
        slicerError = sampledAmplitude - decisionAmplitude;
        timingError = decisionAmplitude(1:end - 1) .* slicerError(2:end) - ...
            decisionAmplitude(2:end) .* slicerError(1:end - 1);
        % Edge filtering: the Mueller-Muller update is only accumulated on
        % symmetric PAM4 transitions, i.e. samples where the current decided
        % amplitude is the exact opposite of the previous one
        % (d[n] == -d[n-1]). This is the same edge-filtered branch used by
        % the offline S-curve script and rejects ISI-heavy inner transitions.
        symmetricTransition = decisionAmplitude(2:end) == ...
            -decisionAmplitude(1:end - 1);
        if any(symmetricTransition)
            meanTimingError = mean(timingError(symmetricTransition));
        else
            meanTimingError = 0;
        end

        phaseError = pdPolarity * meanTimingError;
        deltaCode = loopFilter.update(phaseError);
        phaseInterpolator.update(deltaCode);

        phaseCodeTrace(startIndex, blockIndex) = codeWrapped;
        uiSlipTrace(startIndex, blockIndex) = uiSlip;
        timingErrorTrace(startIndex, blockIndex) = meanTimingError;
        deltaCodeTrace(startIndex, blockIndex) = deltaCode;
        edgeCountTrace(startIndex, blockIndex) = sum(symmetricTransition);
        unwrappedPhaseTrace(startIndex, blockIndex) = ...
            uiSlip * samplePerSymbol + codeWrapped;
    end

    settleWindow = phaseCodeTrace(startIndex, end - settleBlocks + 1:end);
    lockedPhaseCode(startIndex) = round(mean(settleWindow));
    lockedFlag(startIndex) = std(settleWindow) <= lockStdTolerance;

    fprintf(['Start phase %3d/%d: locked=%d, steady phase code=%d, ' ...
        'final MM error=%.4g.\n'], startPhase, samplePerSymbol, ...
        lockedFlag(startIndex), lockedPhaseCode(startIndex), ...
        timingErrorTrace(startIndex, end));
end

commonLockPhase = round(median(lockedPhaseCode(lockedFlag)));
phaseSpread = max(lockedPhaseCode(lockedFlag)) - ...
    min(lockedPhaseCode(lockedFlag));
allPhaseLock = all(lockedFlag) && ...
    all(abs(lockedPhaseCode - commonLockPhase) <= 2);

resultDir = fullfile(testDir, 'result', 'mmpd_cdr_own_data_0.05');
if saveOutputs && ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

blockAxis = 1:numBlocks;
convergenceFigurePath = fullfile(resultDir, ...
    'cdr_phase_convergence.png');
timingErrorFigurePath = fullfile(resultDir, ...
    'cdr_block_timing_error.png');
lockSummaryFigurePath = fullfile(resultDir, ...
    'cdr_locked_phase_vs_start_phase.png');
resultMatPath = fullfile(resultDir, 'mmpd_cdr_result.mat');

if saveOutputs
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 650]);
    plot(blockAxis, phaseCodeTrace.', 'LineWidth', 1.0);
    hold on;
    yline(commonLockPhase, 'k--', sprintf('common lock code %d', ...
        commonLockPhase), 'LineWidth', 1.2);
    yline(referencePhase, 'm:', 'S-curve reference phase 19', ...
        'LineWidth', 1.1);
    hold off;
    grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    ylim([0 samplePerSymbol - 1]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('PI Sampling Phase Code (wrapped, sample index)');
    title(sprintf(['Real-time CDR Phase Convergence: %d start phases, ' ...
        'Kp=%.3g, Ki=%.3g'], numStartPhase, loopKp, loopKi));
    exportgraphics(fig, convergenceFigurePath, 'Resolution', 150);
    close(fig);

    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 650]);
    plot(blockAxis, timingErrorTrace.', 'LineWidth', 1.0);
    hold on;
    yline(0, 'k:');
    hold off;
    grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('Mean Classic MM Timing Error per Block');
    title('Real-time CDR Loop Error Transient per Start Phase');
    exportgraphics(fig, timingErrorFigurePath, 'Resolution', 150);
    close(fig);

    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 620]);
    plot(startPhaseList, lockedPhaseCode, 'bo-', 'LineWidth', 1.3, ...
        'MarkerFaceColor', 'b');
    hold on;
    yline(commonLockPhase, 'k--', sprintf('common lock code %d', ...
        commonLockPhase), 'LineWidth', 1.2);
    hold off;
    grid on;
    xlim([startPhaseList(1) startPhaseList(end)]);
    xlabel('Initial Sampling Phase Code');
    ylabel('Steady-state Locked Phase Code');
    title(sprintf(['Locked Phase vs Start Phase (all-phase lock = %d, ' ...
        'spread = %d code)'], allPhaseLock, phaseSpread));
    exportgraphics(fig, lockSummaryFigurePath, 'Resolution', 150);
    close(fig);
end

result = struct();
result.CachePath = cachePath;
result.AnalysisStartUi = analysisStartUi;
result.AnalysisNumUi = analysisNumUi;
result.SamplePerSymbol = samplePerSymbol;
result.ReferencePhase = referencePhase;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.LevelCenter = levelCenter;
result.SymbolLevels = symbolLevels;
result.CodeToSymbol = codeToSymbol;
result.LoopKp = loopKp;
result.LoopKi = loopKi;
result.LoopMaxDeltaCode = loopMaxDeltaCode;
result.LoopFrequencyLimit = loopFrequencyLimit;
result.PdPolarity = pdPolarity;
result.PiNumBit = piNumBit;
result.BaseUi = baseUi;
result.NumBlocks = numBlocks;
result.StartPhaseList = startPhaseList;
result.PhaseCodeTrace = phaseCodeTrace;
result.UiSlipTrace = uiSlipTrace;
result.UnwrappedPhaseTrace = unwrappedPhaseTrace;
result.TimingErrorTrace = timingErrorTrace;
result.DeltaCodeTrace = deltaCodeTrace;
result.EdgeCountTrace = edgeCountTrace;
result.SettleBlocks = settleBlocks;
result.LockStdTolerance = lockStdTolerance;
result.LockedPhaseCode = lockedPhaseCode;
result.LockedFlag = lockedFlag;
result.CommonLockPhase = commonLockPhase;
result.PhaseSpread = phaseSpread;
result.AllPhaseLock = allPhaseLock;
result.ConvergenceFigurePath = convergenceFigurePath;
result.TimingErrorFigurePath = timingErrorFigurePath;
result.LockSummaryFigurePath = lockSummaryFigurePath;
result.ResultMatPath = resultMatPath;
if saveOutputs
    save(resultMatPath, 'result', '-v7.3');
end

fprintf('\n');
if allPhaseLock
    fprintf(['CDR closed loop passed: all %d start phases locked to ' ...
        'code %d (spread %d code, ref phase %d).\n'], numStartPhase, ...
        commonLockPhase, phaseSpread, referencePhase);
else
    fprintf(['CDR closed loop did NOT reach full-phase lock: %d/%d ' ...
        'phases stable, spread %d code. Retune Kp/Ki/polarity.\n'], ...
        sum(lockedFlag), numStartPhase, phaseSpread);
end
fprintf('Results saved to %s.\n', resultDir);
end

function options = parseLoopOptions(varargin)
%PARSELOOPOPTIONS Resolve CDR loop gains and run flags with tuned defaults.
%   The defaults below are the values selected during the tuning sweep so
%   that a plain mmpd_cdr_own_data_0p05() call reproduces the locked run.
%   Name/value pairs (Kp, Ki, MaxDeltaCode, Polarity, SaveOutputs) allow a
%   caller to override them for retuning without editing the file.

defaults = struct();
defaults.Kp = 1.8;
defaults.Ki = 0.05;
defaults.MaxDeltaCode = 12;
defaults.Polarity = 1;
defaults.SaveOutputs = true;

options = defaults;
if isempty(varargin)
    return;
end
if numel(varargin) == 1 && isstruct(varargin{1})
    provided = varargin{1};
    fieldList = fieldnames(provided);
    for index = 1:numel(fieldList)
        options.(fieldList{index}) = provided.(fieldList{index});
    end
    return;
end
assert(mod(numel(varargin), 2) == 0, ...
    'Loop options must be name/value pairs.');
for index = 1:2:numel(varargin)
    options.(varargin{index}) = varargin{index + 1};
end
end

function outputValid = processOneBlock(blockWaveform, samplePerSymbol, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, cdrFfeCoefficients, cdrFfePreTapCount)
%PROCESSONEBLOCK Quantize and equalize one 64-UI block at the current phase.

adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
ffeModel = cdr_ffe(cdrFfeCoefficients, cdrFfePreTapCount);
physicalCode = adcModel.convertOneBlockFast(blockWaveform, 1);
centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
[blockOutput, ~, blockValid] = ffeModel.processBlock(centeredCode);
outputValid = blockOutput(blockValid);
end

function outputValid = processOnePhase(segment, phase, samplePerSymbol, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, blockUi)
%PROCESSONEPHASE Run the TI ADC and CDR FFE over one fixed segment phase.

numUi = floor((numel(segment) - phase - 1) / samplePerSymbol) + 1;
numBlocks = floor(numUi / blockUi);
numOutput = numBlocks * blockUi;
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
ffeModel = cdr_ffe(cdrFfeCoefficients, cdrFfePreTapCount);
output = zeros(1, numOutput);
valid = false(1, numOutput);
for blockIndex = 1:numBlocks
    firstUi = (blockIndex - 1) * blockUi;
    blockStart = firstUi * samplePerSymbol + phase + 1;
    blockStop = blockStart + nominalBlockLength - 1;
    blockWaveform = segment(blockStart:blockStop);
    physicalCode = adcModel.convertOneBlockFast(blockWaveform, 1);
    centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
    [blockOutput, ~, blockValid] = ffeModel.processBlock(centeredCode);
    outputIndex = (blockIndex - 1) * blockUi + (1:blockUi);
    output(outputIndex) = blockOutput;
    valid(outputIndex) = blockValid;
end
outputValid = output(valid);
end

function [laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol)
%ADCLANEORDERING Return physical-lane reorder indices and local block size.

laneNumber = 1:adcLaneCount;
numTah = adcLaneCount / adcSarPerTah;
lanePhaseIndex = floor((laneNumber - 1) / adcSarPerTah) + 1;
laneSarIndex = mod(laneNumber - 1, adcSarPerTah) + 1;
laneTimeOrderIndex = (laneSarIndex - 1) * numTah + lanePhaseIndex;
[~, laneToTimeOrder] = sort(laneTimeOrderIndex);
nominalBlockLength = (adcLaneCount - 1) * samplePerSymbol + 1;
end

function sample = samplePulseAtPhase(pulse, samplePerSymbol, phase, offset)
%SAMPLEPULSEATPHASE Sample a symbol-pulse response at fixed UI offsets.

[~, pulsePeakIndex] = max(abs(pulse));
mainUi = round((pulsePeakIndex - 1 - phase) / samplePerSymbol);
mainIndex = mainUi * samplePerSymbol + phase + 1;
sampleIndex = mainIndex + offset * samplePerSymbol;
assert(sampleIndex(1) >= 1 && sampleIndex(end) <= numel(pulse), ...
    'Requested symbol-pulse cursor window exceeds available data.');
sample = reshape(pulse(sampleIndex), 1, []);
end

function code = quantizeSamplesWithTiAdc(sample, adcLaneCount, ...
    adcSarPerTah, adcResolutionBits, adcFullRange, samplePerSymbol, ...
    laneToTimeOrder, nominalBlockLength)
%QUANTIZESAMPLEWITHTIADC Quantize up to one 64-UI block of cursor samples.

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
%OPTIMIZECDRFFE Constrain pre1/post1 to 0.05 and minimize other ISI.

mainTapIndex = find(tapOffset == 0, 1);
freeTapMask = tapOffset ~= 0;
regressor = zeros(numel(evalOffset), numel(tapOffset));
for row = 1:numel(evalOffset)
    for column = 1:numel(tapOffset)
        requiredOffset = evalOffset(row) - tapOffset(column);
        channelIndex = find(channelOffset == requiredOffset, 1);
        assert(~isempty(channelIndex), ...
            'CDR FFE design requires an unavailable channel cursor.');
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
regularizationScale = max(trace(normalMatrix) / ...
    size(normalMatrix, 1), eps);
regularization = 1e-8 * regularizationScale;
kktMatrix = [ ...
    normalMatrix + regularization * eye(size(normalMatrix)), ...
    constraintMatrix.'; ...
    constraintMatrix, zeros(size(constraintMatrix, 1))];
kktTarget = [-objectiveMatrix.' * objectiveTarget; constraintTarget];
kktSolution = kktMatrix \ kktTarget;

coefficients = zeros(1, numel(tapOffset));
coefficients(mainTapIndex) = 1;
coefficients(freeTapMask) = kktSolution(1:nnz(freeTapMask));
outputCursor = reshape(regressor * coefficients(:), 1, []);
mainCursor = outputCursor(mainRow);
normalizedCursor = outputCursor / mainCursor;
design = struct();
design.TapOffset = tapOffset;
design.EvalOffset = evalOffset;
design.Regularization = regularization;
design.OutputCursor = outputCursor;
design.NormalizedCursor = normalizedCursor;
design.OtherCursorRms = sqrt(mean( ...
    normalizedCursor(otherCursorMask) .^ 2));
design.OtherCursorMax = max(abs(normalizedCursor(otherCursorMask)));
end

function center = estimatePam4Centers(sample)
%ESTIMATEPAM4CENTERS Estimate four ordered output-code cluster centers.

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

function decision = slicePam4Amplitude(sample, symbolLevels)
%SLICEPAM4AMPLITUDE Slice to full PAM4 amplitudes without sign quantization.

[~, levelIndex] = min(abs(sample(:) - symbolLevels), [], 2);
decision = reshape(symbolLevels(levelIndex), 1, []);
end
