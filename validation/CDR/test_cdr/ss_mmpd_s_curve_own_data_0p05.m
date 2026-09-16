function result = ss_mmpd_s_curve_own_data_0p05()
%SS_MMPD_S_CURVE_OWN_DATA Run ADC, CDR FFE, and SS-MMPD from cached CTLE data.
%   Every phase uses the same 8192-UI CTLE segment. Only the sample phase
%   changes from 0 through 127; Channel and CTLE are never rerun here. The
%   sign-sign MMPD (SS-MMPD) is evaluated three ways: with transition
%   filtering (cdr_pd, symmetric 0<->3 and 1<->2 transitions weighted 2),
%   without transition filtering (uniform weight 1 1 1 1), and using the
%   symmetric transitions only (weight 1 on 0<->3 and 1<->2, all other
%   transitions dropped). Both control curves are replicated in this script
%   only; cdr_pd.m is not modified. By construction the three curves satisfy
%   FilteredMean = UniformMean + SymmetricOnlyMean.

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
eyeNumUi = 1024;
ctleEyeWaveform = double(cacheFile.ctleOutput( ...
    1, 1:eyeNumUi * samplePerSymbol));

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

referenceOutput = processOnePhase(ctleSegment, referencePhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, ...
    adcFullRange, adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, adcBlockUi);
levelCenter = estimatePam4Centers(referenceOutput);
symbolLevels = [-3 -1 1 3];
codeToSymbol = polyfit(levelCenter, symbolLevels, 1);

phaseDetector = cdr_pd('pam4', 1);

phaseAxis = 0:samplePerSymbol - 1;
phaseOffsetSample = mod(phaseAxis - referencePhase + samplePerSymbol / 2, samplePerSymbol) - samplePerSymbol / 2;
filteredMean = zeros(1, samplePerSymbol);
uniformMean = zeros(1, samplePerSymbol);
symmetricOnlyMean = zeros(1, samplePerSymbol);
validTransitionCount = zeros(1, samplePerSymbol);
symmetricTransitionCount = zeros(1, samplePerSymbol);
for phase = phaseAxis
    if phase == referencePhase
        ffeOutput = referenceOutput;
    else
        ffeOutput = processOnePhase(ctleSegment, phase, ...
            samplePerSymbol, adcLaneCount, adcSarPerTah, ...
            adcResolutionBits, adcFullRange, adcZeroCode, ...
            laneToTimeOrder, nominalBlockLength, cdrFfeCoefficients, ...
            cdrFfePreTapCount, adcBlockUi);
    end
    sampledAmplitude = polyval(codeToSymbol, ffeOutput);
    decisionAmplitude = slicePam4Amplitude(sampledAmplitude, symbolLevels);
    slicerError = sampledAmplitude - decisionAmplitude;
    dataSymbol = round((decisionAmplitude + 3) / 2);
    errorBit = double(slicerError >= 0);

    dataPrev = dataSymbol(1:end - 1);
    dataCurr = dataSymbol(2:end);
    errorPrev = errorBit(1:end - 1);
    errorCurr = errorBit(2:end);

    [filteredDecision, validTransition] = phaseDetector.mmpdFast( ...
        dataPrev, errorPrev, dataCurr, errorCurr);
    filteredMean(phase + 1) = mean(double(filteredDecision));

    uniformDecision = ssMmpdUniform(phaseDetector.Polarity, ...
        dataPrev, errorPrev, dataCurr, errorCurr);
    uniformMean(phase + 1) = mean(double(uniformDecision));

    symmetricOnlyDecision = ssMmpdSymmetricOnly(phaseDetector.Polarity, ...
        dataPrev, errorPrev, dataCurr, errorCurr);
    symmetricOnlyMean(phase + 1) = mean(double(symmetricOnlyDecision));

    validTransitionCount(phase + 1) = sum(validTransition);
    symmetricTransition = (dataPrev == 0 & dataCurr == 3) | ...
        (dataPrev == 3 & dataCurr == 0) | ...
        (dataPrev == 1 & dataCurr == 2) | ...
        (dataPrev == 2 & dataCurr == 1);
    symmetricTransitionCount(phase + 1) = sum(symmetricTransition);
    if phase == 0 || mod(phase + 1, 16) == 0 || phase == phaseAxis(end)
        fprintf('SS-MMPD S-curve phase progress: %d / %d.\n', ...
            phase + 1, samplePerSymbol);
    end
end

[~, filteredMinimumIndex] = min(abs(filteredMean));
filteredNearestZeroPhase = filteredMinimumIndex - 1;
[~, uniformMinimumIndex] = min(abs(uniformMean));
uniformNearestZeroPhase = uniformMinimumIndex - 1;
[~, symmetricOnlyMinimumIndex] = min(abs(symmetricOnlyMean));
symmetricOnlyNearestZeroPhase = symmetricOnlyMinimumIndex - 1;
assert(max(abs(filteredMean - (uniformMean + symmetricOnlyMean))) < 1e-12, ...
    'FilteredMean must equal UniformMean + SymmetricOnlyMean by weighting.');
[filteredZeroCrossingPhase, filteredZeroCrossingSlope] = ...
    findWrappedZeroCrossings(phaseAxis, filteredMean, samplePerSymbol);
[uniformZeroCrossingPhase, uniformZeroCrossingSlope] = ...
    findWrappedZeroCrossings(phaseAxis, uniformMean, samplePerSymbol);
[symmetricOnlyZeroCrossingPhase, symmetricOnlyZeroCrossingSlope] = ...
    findWrappedZeroCrossings(phaseAxis, symmetricOnlyMean, samplePerSymbol);
[centeredPhaseOffsetSample, centeredOrder] = sort(phaseOffsetSample);
centeredPhaseOffsetUi = centeredPhaseOffsetSample / samplePerSymbol;
centeredFilteredMean = filteredMean(centeredOrder);
centeredUniformMean = uniformMean(centeredOrder);
centeredSymmetricOnlyMean = symmetricOnlyMean(centeredOrder);
[filteredCenteredZeroCrossingUi, filteredCenteredZeroCrossingSlope] = ...
    findLinearZeroCrossings(centeredPhaseOffsetUi, centeredFilteredMean);
[uniformCenteredZeroCrossingUi, uniformCenteredZeroCrossingSlope] = ...
    findLinearZeroCrossings(centeredPhaseOffsetUi, centeredUniformMean);
[symmetricOnlyCenteredZeroCrossingUi, ...
    symmetricOnlyCenteredZeroCrossingSlope] = ...
    findLinearZeroCrossings(centeredPhaseOffsetUi, ...
    centeredSymmetricOnlyMean);
totalUnitUiResponseNormalized = cdrFfeDesign.NormalizedCursor;
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == -1) - 0.05) < 1e-6);
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 0) - 1) < 1e-12);
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 1) - 0.05) < 1e-6);

resultDir = fullfile(testDir, 'result', 'ss_mmpd_s_curve_own_data_0.05');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

comparisonFigurePath = fullfile(resultDir, ...
    'ss_mmpd_filtered_and_uniform_s_curve.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1000 650]);
plot(centeredPhaseOffsetUi, centeredFilteredMean, ...
    'b-', 'LineWidth', 1.5);
hold on;
plot(centeredPhaseOffsetUi, centeredUniformMean, ...
    'r-', 'LineWidth', 1.5);
plot(centeredPhaseOffsetUi, centeredSymmetricOnlyMean, ...
    'Color', [0 0.6 0], 'LineStyle', '-', 'LineWidth', 1.5);
yline(0, 'k:');
xline(0, 'm--', 'phase 19', 'LineWidth', 1.1);
hold off;
grid on;
xlim([-0.5 0.5]);
xlabel('Sampling Phase Offset from Phase 19 (UI)');
ylabel('Mean SS-MM Phase Decision');
legend({'With Transition Filtering (symmetric x2)', ...
    'Without Transition Filtering (weight 1 1 1 1)', ...
    'Symmetric Transitions Only (weight 1)'}, 'Location', 'best');
title(sprintf(['SS-MMPD Comparison: same %d UI, ' ...
    'start UI=%d'], analysisNumUi, analysisStartUi));
exportgraphics(fig, comparisonFigurePath, 'Resolution', 150);
close(fig);

ctleEyeFigurePath = fullfile(resultDir, ...
    'ctle_output_first_1024_ui_eye.png');
eyeTrace = reshape(ctleEyeWaveform, 2 * samplePerSymbol, []);
eyeTimeUi = (0:2 * samplePerSymbol - 1) / samplePerSymbol;
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1000 650]);
plot(eyeTimeUi, eyeTrace, 'Color', [0.1 0.35 0.75 0.12]);
hold on;
xline(referencePhase / samplePerSymbol, 'm--', 'reference phase');
xline(1 + referencePhase / samplePerSymbol, 'm--');
hold off;
grid on;
xlim([0 2]);
xlabel('Time (UI)');
ylabel('CTLE Output (V)');
title('Cached CTLE Output Eye: First 1024 UI');
exportgraphics(fig, ctleEyeFigurePath, 'Resolution', 150);
close(fig);

unitUiFigurePath = fullfile(resultDir, ...
    'cdr_ffe_output_unit_ui_response.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1000 620]);
stem(cdrFfeEvalOffset, totalUnitUiResponseNormalized, 'ro', ...
    'filled', 'LineWidth', 1.2, 'MarkerSize', 6);
grid on;
xlim([cdrFfeEvalOffset(1) cdrFfeEvalOffset(end)]);
ylim([-0.2 1.1]);
xline(0, 'k--');
yline(0, 'k:');
yline(0.05, 'b:', 'pre1/post1 target');
xlabel('Cursor Offset (UI)');
ylabel('Normalized Equalized Code');
title('Cached Channel + CTLE + ADC + CDR FFE Unit-UI Response');
exportgraphics(fig, unitUiFigurePath, 'Resolution', 150);
close(fig);

histogramFigurePath = fullfile(resultDir, ...
    'cdr_ffe_output_histogram.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 900 600]);
histogram(referenceOutput, 200, 'Normalization', 'probability', ...
    'FaceColor', [0.2 0.4 0.8], 'EdgeColor', 'none');
grid on;
xlabel('CDR FFE Output Code (centered)');
ylabel('Probability');
title(sprintf('CDR FFE Histogram at Reference Phase %d/128', ...
    referencePhase));
exportgraphics(fig, histogramFigurePath, 'Resolution', 150);
close(fig);

result = struct();
result.CachePath = cachePath;
result.AnalysisStartUi = analysisStartUi;
result.AnalysisNumUi = analysisNumUi;
result.SegmentFirstSample = segmentFirstSample;
result.SegmentLastSample = segmentLastSample;
result.AllPhasesUseSameSegment = true;
result.SamplePerSymbol = samplePerSymbol;
result.PhaseAxis = phaseAxis;
result.ReferencePhase = referencePhase;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.CdrFfeTapOffset = cdrFfeTapOffset;
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.LevelCenter = levelCenter;
result.SymbolLevels = symbolLevels;
result.CodeToSymbol = codeToSymbol;
result.PdPolarity = phaseDetector.Polarity;
result.FilteredMean = filteredMean;
result.UniformMean = uniformMean;
result.SymmetricOnlyMean = symmetricOnlyMean;
result.ValidTransitionCount = validTransitionCount;
result.SymmetricTransitionCount = symmetricTransitionCount;
result.CenteredPhaseOffsetSample = centeredPhaseOffsetSample;
result.CenteredPhaseOffsetUi = centeredPhaseOffsetUi;
result.CenteredFilteredMean = centeredFilteredMean;
result.CenteredUniformMean = centeredUniformMean;
result.CenteredSymmetricOnlyMean = centeredSymmetricOnlyMean;
result.FilteredNearestZeroPhase = filteredNearestZeroPhase;
result.UniformNearestZeroPhase = uniformNearestZeroPhase;
result.SymmetricOnlyNearestZeroPhase = symmetricOnlyNearestZeroPhase;
result.FilteredZeroCrossingPhase = filteredZeroCrossingPhase;
result.FilteredZeroCrossingSlope = filteredZeroCrossingSlope;
result.UniformZeroCrossingPhase = uniformZeroCrossingPhase;
result.UniformZeroCrossingSlope = uniformZeroCrossingSlope;
result.SymmetricOnlyZeroCrossingPhase = symmetricOnlyZeroCrossingPhase;
result.SymmetricOnlyZeroCrossingSlope = symmetricOnlyZeroCrossingSlope;
result.FilteredCenteredZeroCrossingUi = filteredCenteredZeroCrossingUi;
result.FilteredCenteredZeroCrossingSlope = filteredCenteredZeroCrossingSlope;
result.UniformCenteredZeroCrossingUi = uniformCenteredZeroCrossingUi;
result.UniformCenteredZeroCrossingSlope = uniformCenteredZeroCrossingSlope;
result.SymmetricOnlyCenteredZeroCrossingUi = ...
    symmetricOnlyCenteredZeroCrossingUi;
result.SymmetricOnlyCenteredZeroCrossingSlope = ...
    symmetricOnlyCenteredZeroCrossingSlope;
result.ReferenceOutput = referenceOutput;
result.ComparisonFigurePath = comparisonFigurePath;
result.CtleEyeStartUi = 0;
result.CtleEyeNumUi = eyeNumUi;
result.CtleEyeFigurePath = ctleEyeFigurePath;
result.UnitUiFigurePath = unitUiFigurePath;
result.HistogramFigurePath = histogramFigurePath;
resultMatPath = fullfile(resultDir, 'ss_mmpd_s_curve_result.mat');
result.ResultMatPath = resultMatPath;
save(resultMatPath, 'result', '-v7.3');

fprintf(['SS-MMPD S-curve passed: phases 0:127 used the same UI range ' ...
    '[%d,%d), filtered nearest-zero phase %d, uniform nearest-zero ' ...
    'phase %d.\n'], analysisStartUi, analysisStartUi + analysisNumUi, ...
    filteredNearestZeroPhase, uniformNearestZeroPhase);
fprintf('Filtered SS-MM zero crossings: %s.\n', ...
    mat2str(filteredZeroCrossingPhase, 6));
fprintf('Uniform SS-MM zero crossings: %s.\n', ...
    mat2str(uniformZeroCrossingPhase, 6));
fprintf('Symmetric-only SS-MM zero crossings: %s.\n', ...
    mat2str(symmetricOnlyZeroCrossingPhase, 6));
fprintf('Results saved to %s.\n', resultDir);
end

function decision = ssMmpdUniform(polarity, dataPrev, errorPrev, ...
    dataCurr, errorCurr)
%SSMMPDUNIFORM SS-MMPD decision without transition filtering (weight 1).
%   Mirrors cdr_pd.mmpdFast exactly, except every valid transition carries
%   uniform weight 1 (the four symmetric 0<->3 and 1<->2 transitions are no
%   longer boosted to weight 2). This control lives in the test script only
%   and does not modify cdr_pd.m.

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

function decision = ssMmpdSymmetricOnly(polarity, dataPrev, errorPrev, ...
    dataCurr, errorCurr)
%SSMMPDSYMMETRICONLY SS-MMPD decision from symmetric transitions only.
%   Mirrors cdr_pd.mmpdFast but keeps only the four symmetric transitions
%   (0<->3 and 1<->2) at weight 1; every other transition is dropped. This
%   control lives in the test script only and does not modify cdr_pd.m.

sameError = errorPrev == errorCurr;
errorHigh = errorPrev ~= 0;
symmetricTransition = (dataPrev == 0 & dataCurr == 3) | ...
    (dataPrev == 3 & dataCurr == 0) | ...
    (dataPrev == 1 & dataCurr == 2) | ...
    (dataPrev == 2 & dataCurr == 1);
risingTransition = dataCurr > dataPrev;
valid = sameError & symmetricTransition;
early = valid & ((~risingTransition & errorHigh) | ...
    (risingTransition & ~errorHigh));

polarity = int8(polarity);
decision = zeros(size(valid), 'int8');
decision(valid) = -polarity;
decision(early) = polarity;
end

function [crossing, slope] = findWrappedZeroCrossings(phase, curve, period)
%FINDWRAPPEDZEROCROSSINGS Linearly interpolate all periodic zero crossings.

crossing = [];
slope = [];
for index = 1:numel(phase)
    nextIndex = mod(index, numel(phase)) + 1;
    nextPhase = phase(nextIndex);
    if nextIndex == 1
        nextPhase = period;
    end
    firstValue = curve(index);
    nextValue = curve(nextIndex);
    if firstValue == 0
        crossing(end + 1) = phase(index); %#ok<AGROW>
        slope(end + 1) = nextValue - firstValue; %#ok<AGROW>
    elseif firstValue * nextValue < 0
        localSlope = (nextValue - firstValue) / ...
            (nextPhase - phase(index));
        crossing(end + 1) = mod(phase(index) - ...
            firstValue / localSlope, period); %#ok<AGROW>
        slope(end + 1) = localSlope; %#ok<AGROW>
    end
end
end

function [crossing, slope] = findLinearZeroCrossings(axis, curve)
%FINDLINEARZEROCROSSINGS Interpolate zero crossings on an ordered axis.

crossing = [];
slope = [];
for index = 1:numel(axis) - 1
    firstValue = curve(index);
    nextValue = curve(index + 1);
    localSlope = (nextValue - firstValue) / ...
        (axis(index + 1) - axis(index));
    if firstValue == 0
        crossing(end + 1) = axis(index); %#ok<AGROW>
        slope(end + 1) = localSlope; %#ok<AGROW>
    elseif firstValue * nextValue < 0
        crossing(end + 1) = axis(index) - ...
            firstValue / localSlope; %#ok<AGROW>
        slope(end + 1) = localSlope; %#ok<AGROW>
    end
end
end

function outputValid = processOnePhase(segment, phase, samplePerSymbol, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, blockUi)
%PROCESSONEPHASE Run the existing TI ADC and CDR FFE over one fixed segment.

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
