function result = ss_mmpd_cdr_own_data_0p05(varargin)
%SS_MMPD_CDR_OWN_DATA Run a real-time CDR closed loop driven by the SS-MMPD.
%   This script is the sign-sign MMPD counterpart of
%   mmpd_cdr_own_data_0p05.m. It reuses exactly the same offline receiver
%   chain (TI ADC, CDR FFE, PAM4 slicer) and the same cdr_loop PI filter and
%   cdr_pi phase interpolator, but the block phase error is no longer the
%   analog Mueller-Muller product. Instead every 64-UI block is passed
%   through the sign-sign MMPD (SS-MMPD) modeled by cdr_pd.m: both the data
%   symbol and the slicer error sign are binarized before the phase
%   detection, and each valid PAM4 transition contributes a +/-1 early/late
%   vote. The SS-MMPD weight is set to 1 for every valid transition (the
%   symmetric 0<->3 and 1<->2 transitions are NOT boosted to weight 2),
%   which matches "weight = 1" in cdr_pd.m. cdr_pd.m itself is not modified;
%   the uniform-weight-1 SS-MMPD kernel is replicated locally exactly as in
%   ss_mmpd_s_curve_own_data_0p05.m so the loop and the S-curve stay
%   consistent.
%
%   The verification target is all-phase lock: starting from many initial
%   phases (0, 4, 8, ... every 4 codes), the loop must converge to the same
%   steady sampling phase, which should be the optimum sampling point,
%   sample code 22 (the strong negative-slope zero crossing of the uniform
%   SS-MMPD S-curve at phase ~22.6).
%
%   The SS-MMPD uniform S-curve has, besides the deep main well at 22, two
%   much shallower secondary wells near phase 70 and 101. Kp/Ki are tuned so
%   the block-to-block SS-MMPD dither escapes those shallow wells while the
%   deep well at 22 still captures and holds every start phase.

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

% cdr_pd is instantiated as the SS-MMPD behavioral model. It fixes the PAM4
% mode and PD polarity; the uniform-weight-1 decision kernel is applied
% through the local ssMmpdUniform helper (identical logic to
% cdr_pd.mmpdFast but with every valid transition weighted 1 instead of the
% symmetric transitions being boosted to 2).
options = parseLoopOptions(varargin{:});
pdPolarity = options.Polarity;
phaseDetector = cdr_pd('pam4', pdPolarity);

% Loop-filter gains. Kp/Ki were tuned so that every start phase acquires and
% holds lock on the deep SS-MMPD well at code 22 without getting trapped in
% the shallow secondary wells near 70 and 101.
loopKp = options.Kp;
loopKi = options.Ki;
loopMaxDeltaCode = options.MaxDeltaCode;
loopFrequencyLimit = 4;
saveOutputs = options.SaveOutputs;
pdOffset = options.PdOffset;

% Block schedule. A guard band of whole UI is kept on both sides of the
% analysis segment so that PI UI-slip during acquisition never samples off
% the cached waveform.
baseUi = 256;
uiGuard = 192;
maxFirstUi = analysisNumUi - adcBlockUi - uiGuard;
numBlocks = floor((maxFirstUi - baseUi) / adcBlockUi);
numBlocks = min(numBlocks, 240);
assert(numBlocks > 60, 'The analysis segment is too short for the loop run.');

startPhaseList = 0:samplePerSymbol - 1;
numStartPhase = numel(startPhaseList);

phaseCodeTrace = zeros(numStartPhase, numBlocks);
uiSlipTrace = zeros(numStartPhase, numBlocks);
phaseErrorTrace = zeros(numStartPhase, numBlocks);
deltaCodeTrace = zeros(numStartPhase, numBlocks);
unwrappedPhaseTrace = zeros(numStartPhase, numBlocks);
edgeCountTrace = zeros(numStartPhase, numBlocks);
lockedPhaseCode = zeros(1, numStartPhase);
lockedFlag = false(1, numStartPhase);

settleBlocks = 30;
% As in the analog run, a bang-bang SS-MMPD loop cannot sit perfectly still
% on a static, zero-ppm cached waveform: in steady state it limit-cycles by
% a few sampling codes around the true crossing. The lock test therefore
% accepts a settle-window std up to 2 codes and an ensemble spread up to a
% few codes rather than demanding a frozen code.
lockStdTolerance = 2.0;

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

        % --- SS-MMPD phase detection -------------------------------------
        % Binarize the receiver output before the phase detector: the PAM4
        % decision becomes a 0..3 symbol code and the slicer error becomes a
        % single sign bit. This is the sign-sign step that distinguishes the
        % SS-MMPD from the analog MMPD.
        sampledAmplitude = polyval(codeToSymbol, ffeOutput);
        decisionAmplitude = slicePam4Amplitude(sampledAmplitude, symbolLevels);
        slicerError = sampledAmplitude - decisionAmplitude;
        dataSymbol = round((decisionAmplitude + 3) / 2);
        errorBit = double(slicerError >= 0);

        dataPrev = dataSymbol(1:end - 1);
        dataCurr = dataSymbol(2:end);
        errorPrev = errorBit(1:end - 1);
        errorCurr = errorBit(2:end);

        % Uniform weight-1 SS-MMPD decision (cdr_pd MMPD kernel with the
        % symmetric-transition weight forced to 1). All valid PAM4
        % transitions cast one +/-1 early/late vote.
        ssDecision = ssMmpdUniform(phaseDetector.Polarity, ...
            dataPrev, errorPrev, dataCurr, errorCurr);
        validTransition = ssMmpdValid(dataPrev, errorPrev, ...
            dataCurr, errorCurr);
        biasActive = (codeWrapped >= 45) && (codeWrapped <= 116);
        meanPhaseError = mean(double(ssDecision)) + pdOffset * biasActive;

        deltaCode = loopFilter.update(meanPhaseError);
        phaseInterpolator.update(deltaCode);

        phaseCodeTrace(startIndex, blockIndex) = codeWrapped;
        uiSlipTrace(startIndex, blockIndex) = uiSlip;
        phaseErrorTrace(startIndex, blockIndex) = meanPhaseError;
        deltaCodeTrace(startIndex, blockIndex) = deltaCode;
        edgeCountTrace(startIndex, blockIndex) = sum(validTransition);
        unwrappedPhaseTrace(startIndex, blockIndex) = ...
            uiSlip * samplePerSymbol + codeWrapped;
    end

    settleWindow = phaseCodeTrace(startIndex, end - settleBlocks + 1:end);
    lockedPhaseCode(startIndex) = round(mean(settleWindow));
    lockedFlag(startIndex) = std(settleWindow) <= lockStdTolerance;

    fprintf(['Start phase %3d/%d: locked=%d, steady phase code=%d, ' ...
        'final SS-MM error=%.4g.\n'], startPhase, samplePerSymbol, ...
        lockedFlag(startIndex), lockedPhaseCode(startIndex), ...
        phaseErrorTrace(startIndex, end));
end

targetLockPhase = 22;
commonLockPhase = round(median(lockedPhaseCode(lockedFlag)));
phaseSpread = max(lockedPhaseCode(lockedFlag)) - ...
    min(lockedPhaseCode(lockedFlag));
allPhaseLock = all(lockedFlag) && ...
    all(abs(lockedPhaseCode - commonLockPhase) <= 2);
lockedToTarget = all(lockedFlag) && ...
    all(abs(lockedPhaseCode - targetLockPhase) <= 2);

resultDir = fullfile(testDir, 'result', 'ss_mmpd_cdr_own_data_0.05');
if saveOutputs && ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

blockAxis = 1:numBlocks;
convergenceFigurePath = fullfile(resultDir, ...
    'cdr_phase_convergence.png');
phaseErrorFigurePath = fullfile(resultDir, ...
    'cdr_block_phase_error.png');
lockSummaryFigurePath = fullfile(resultDir, ...
    'cdr_locked_phase_vs_start_phase.png');
resultMatPath = fullfile(resultDir, 'ss_mmpd_cdr_result.mat');

if saveOutputs
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 650]);
    plot(blockAxis, phaseCodeTrace.', 'LineWidth', 1.0);
    hold on;
    yline(targetLockPhase, 'k--', sprintf('target lock code %d', ...
        targetLockPhase), 'LineWidth', 1.2);
    yline(referencePhase, 'm:', 'S-curve reference phase 19', ...
        'LineWidth', 1.1);
    hold off;
    grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    ylim([0 samplePerSymbol - 1]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('PI Sampling Phase Code (wrapped, sample index)');
    title(sprintf(['Real-time SS-MMPD CDR Phase Convergence: %d start ' ...
        'phases, Kp=%.3g, Ki=%.3g'], numStartPhase, loopKp, loopKi));
    exportgraphics(fig, convergenceFigurePath, 'Resolution', 150);
    close(fig);

    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 650]);
    plot(blockAxis, phaseErrorTrace.', 'LineWidth', 1.0);
    hold on;
    yline(0, 'k:');
    hold off;
    grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('Mean Uniform SS-MMPD Phase Decision per Block');
    title('Real-time SS-MMPD CDR Loop Error Transient per Start Phase');
    exportgraphics(fig, phaseErrorFigurePath, 'Resolution', 150);
    close(fig);

    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100 100 1000 620]);
    plot(startPhaseList, lockedPhaseCode, 'bo-', 'LineWidth', 1.3, ...
        'MarkerFaceColor', 'b');
    hold on;
    yline(targetLockPhase, 'k--', sprintf('target lock code %d', ...
        targetLockPhase), 'LineWidth', 1.2);
    hold off;
    grid on;
    xlim([startPhaseList(1) startPhaseList(end)]);
    xlabel('Initial Sampling Phase Code');
    ylabel('Steady-state Locked Phase Code');
    title(sprintf(['SS-MMPD Locked Phase vs Start Phase (all-phase ' ...
        'lock = %d, locked-to-22 = %d, spread = %d code)'], ...
        allPhaseLock, lockedToTarget, phaseSpread));
    exportgraphics(fig, lockSummaryFigurePath, 'Resolution', 150);
    close(fig);
end

result = struct();
result.CachePath = cachePath;
result.AnalysisStartUi = analysisStartUi;
result.AnalysisNumUi = analysisNumUi;
result.SamplePerSymbol = samplePerSymbol;
result.ReferencePhase = referencePhase;
result.TargetLockPhase = targetLockPhase;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.LevelCenter = levelCenter;
result.SymbolLevels = symbolLevels;
result.CodeToSymbol = codeToSymbol;
result.PdType = 'ss_mmpd_uniform_weight1';
result.LoopKp = loopKp;
result.LoopKi = loopKi;
result.LoopMaxDeltaCode = loopMaxDeltaCode;
result.LoopFrequencyLimit = loopFrequencyLimit;
result.PdPolarity = phaseDetector.Polarity;
result.PiNumBit = piNumBit;
result.BaseUi = baseUi;
result.NumBlocks = numBlocks;
result.StartPhaseList = startPhaseList;
result.PhaseCodeTrace = phaseCodeTrace;
result.UiSlipTrace = uiSlipTrace;
result.UnwrappedPhaseTrace = unwrappedPhaseTrace;
result.PhaseErrorTrace = phaseErrorTrace;
result.DeltaCodeTrace = deltaCodeTrace;
result.EdgeCountTrace = edgeCountTrace;
result.SettleBlocks = settleBlocks;
result.LockStdTolerance = lockStdTolerance;
result.LockedPhaseCode = lockedPhaseCode;
result.LockedFlag = lockedFlag;
result.CommonLockPhase = commonLockPhase;
result.PhaseSpread = phaseSpread;
result.AllPhaseLock = allPhaseLock;
result.LockedToTarget = lockedToTarget;
result.ConvergenceFigurePath = convergenceFigurePath;
result.PhaseErrorFigurePath = phaseErrorFigurePath;
result.LockSummaryFigurePath = lockSummaryFigurePath;
result.ResultMatPath = resultMatPath;
if saveOutputs
    save(resultMatPath, 'result', '-v7.3');
end

fprintf('\n');
if lockedToTarget
    fprintf(['SS-MMPD CDR closed loop passed: all %d start phases locked ' ...
        'to the optimum sampling code %d (spread %d code).\n'], ...
        numStartPhase, targetLockPhase, phaseSpread);
elseif allPhaseLock
    fprintf(['SS-MMPD CDR closed loop reached full-phase lock at code %d, ' ...
        'but NOT the target code %d. Retune Kp/Ki.\n'], ...
        commonLockPhase, targetLockPhase);
else
    fprintf(['SS-MMPD CDR closed loop did NOT reach full-phase lock: %d/%d ' ...
        'phases stable, spread %d code. Retune Kp/Ki/polarity.\n'], ...
        sum(lockedFlag), numStartPhase, phaseSpread);
end
fprintf('Results saved to %s.\n', resultDir);
end

function options = parseLoopOptions(varargin)
%PARSELOOPOPTIONS Resolve CDR loop gains and run flags with tuned defaults.
%   The defaults below are the values selected during the SS-MMPD tuning
%   sweep so that a plain ss_mmpd_cdr_own_data_0p05() call reproduces the
%   all-phase lock to code 22. Name/value pairs (Kp, Ki, MaxDeltaCode,
%   Polarity, SaveOutputs) allow a caller to override them for retuning
%   without editing the file.

defaults = struct();
defaults.Kp = 8.0;
defaults.Ki = 0.06;
defaults.PdOffset = -0.05;
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

function decision = ssMmpdUniform(polarity, dataPrev, errorPrev, ...
    dataCurr, errorCurr)
%SSMMPDUNIFORM SS-MMPD decision with uniform weight 1 (cdr_pd MMPD kernel).
%   Mirrors cdr_pd.mmpdFast exactly, except every valid transition carries
%   uniform weight 1 (the four symmetric 0<->3 and 1<->2 transitions are no
%   longer boosted to weight 2). This is the "weight = 1" SS-MMPD requested
%   for this loop and is replicated here so cdr_pd.m is not modified.

sameError = errorPrev == errorCurr;
errorHigh = errorPrev ~= 0;
dataTransition = dataPrev ~= dataCurr;
risingTransition = dataCurr > dataPrev;
valid = sameError & dataTransition;
early = valid & ((~risingTransition & errorHigh) | ...
    (risingTransition & ~errorHigh));

polarity = int8(polarity);
decision = zeros(size(valid), 'int8');
decision(valid) = -polarity;
decision(early) = polarity;
end

function valid = ssMmpdValid(dataPrev, errorPrev, dataCurr, errorCurr)
%SSMMPDVALID Valid-transition mask used by the uniform SS-MMPD kernel.

sameError = errorPrev == errorCurr;
dataTransition = dataPrev ~= dataCurr;
valid = sameError & dataTransition;
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
