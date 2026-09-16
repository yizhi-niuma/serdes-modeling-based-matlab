function result = mmpd_s_curve_own_data_0p05_v1()
%MMPD_S_CURVE_OWN_DATA_0P05_V1 Run ADC, CDR FFE, and MMPD from cached CTLE data.
%   V1 variant of MMPD_S_CURVE_OWN_DATA_0P05. The only functional change is
%   the CDR FFE geometry: it is reduced from 10 taps (3 pre + main + 6 post)
%   to a typical 6-tap layout (2 pre + main + 3 post). The tap weights are
%   re-optimized by the same constrained solver so that the normalized
%   equalized unit-UI response still satisfies pre1 = post1 = 0.05, main = 1,
%   while every other cursor is minimized in a least-squares sense.
%   Every phase uses the same CTLE segment. Only the sample phase changes
%   from 0 through 127; Channel and CTLE are never rerun here.

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
% Six-tap CDR FFE: 2 precursor taps, 1 main tap, 3 postcursor taps.
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
referenceAmplitude = polyval(codeToSymbol, referenceOutput);
referenceDecision = slicePam4Amplitude(referenceAmplitude, symbolLevels);

phaseAxis = 0:samplePerSymbol - 1;
phaseOffsetSample = mod(phaseAxis - referencePhase + samplePerSymbol / 2, samplePerSymbol) - samplePerSymbol / 2;
loopMean = zeros(1, samplePerSymbol);
referenceMean = zeros(1, samplePerSymbol);
symmetricMean = zeros(1, samplePerSymbol);
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

    unwrappedPhase = referencePhase + phaseOffsetSample(phase + 1);
    referenceUiShift = round((phase - unwrappedPhase) / samplePerSymbol);
    [referenceSample, alignedReferenceDecision] = alignFixedDecision( ...
        sampledAmplitude, referenceDecision, referenceUiShift);
    referenceError = referenceSample - alignedReferenceDecision;
    referenceTimingError = alignedReferenceDecision(1:end - 1) .* ...
        referenceError(2:end) - alignedReferenceDecision(2:end) .* ...
        referenceError(1:end - 1);
    referenceMean(phase + 1) = mean(referenceTimingError);

    decisionAmplitude = slicePam4Amplitude(sampledAmplitude, symbolLevels);
    slicerError = sampledAmplitude - decisionAmplitude;
    timingError = decisionAmplitude(1:end - 1) .* slicerError(2:end) - ...
        decisionAmplitude(2:end) .* slicerError(1:end - 1);
    loopMean(phase + 1) = mean(timingError);
    symmetricTransition = decisionAmplitude(2:end) == ...
        -decisionAmplitude(1:end - 1);
    symmetricTransitionCount(phase + 1) = sum(symmetricTransition);
    assert(any(symmetricTransition), ...
        'No symmetric PAM4 transitions remain at phase %d.', phase);
    symmetricMean(phase + 1) = mean(timingError(symmetricTransition));
    if phase == 0 || mod(phase + 1, 16) == 0 || phase == phaseAxis(end)
        fprintf('MMPD S-curve phase progress: %d / %d.\n', ...
            phase + 1, samplePerSymbol);
    end
end

[~, minimumMagnitudeIndex] = min(abs(loopMean));
nearestZeroPhase = minimumMagnitudeIndex - 1;
[zeroCrossingPhase, zeroCrossingSlope] = findWrappedZeroCrossings( ...
    phaseAxis, loopMean, samplePerSymbol);
[centeredPhaseOffsetSample, centeredOrder] = sort(phaseOffsetSample);
centeredPhaseOffsetUi = centeredPhaseOffsetSample / samplePerSymbol;
centeredReferenceMean = referenceMean(centeredOrder);
centeredSymmetricMean = symmetricMean(centeredOrder);
centeredLoopMean = loopMean(centeredOrder);
[referenceZeroCrossingOffsetUi, referenceZeroCrossingSlope] = ...
    findLinearZeroCrossings(centeredPhaseOffsetUi, centeredReferenceMean);
[symmetricZeroCrossingOffsetUi, symmetricZeroCrossingSlope] = ...
    findLinearZeroCrossings(centeredPhaseOffsetUi, centeredSymmetricMean);
totalUnitUiResponseNormalized = cdrFfeDesign.NormalizedCursor;
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == -1) - 0.05) < 1e-6);
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 0) - 1) < 1e-12);
assert(abs(totalUnitUiResponseNormalized(cdrFfeEvalOffset == 1) - 0.05) < 1e-6);

resultDir = fullfile(testDir, 'result', 'mmpd_s_curve_own_data_0p05');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

comparisonFigurePath = fullfile(resultDir, ...
    'mmpd_reference_and_symmetric_s_curve.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1000 650]);
plot(centeredPhaseOffsetUi, centeredReferenceMean, ...
    'b-', 'LineWidth', 1.5);
hold on;
plot(centeredPhaseOffsetUi, centeredSymmetricMean, ...
    'r-', 'LineWidth', 1.5);
plot(centeredPhaseOffsetUi, centeredLoopMean, ...
    'g-', 'LineWidth', 1.5);
yline(0, 'k:');
xline(0, 'm--', 'phase 19', 'LineWidth', 1.1);
hold off;
grid on;
xlim([-0.5 0.5]);
xlabel('Sampling Phase Offset from Phase 19 (UI)');
ylabel('Mean Classic MM Timing Error');
legend({'Phase-19 Fixed Decision', ...
    'Live Symmetric Transitions', ...
    'Live All Transitions'}, 'Location', 'best');
title(sprintf(['Classic MMPD Comparison (6-tap CDR FFE): same %d UI, ' ...
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
title('Cached Channel + CTLE + ADC + 6-tap CDR FFE Unit-UI Response');
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
result.CdrFfePreTapCount = cdrFfePreTapCount;
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.LevelCenter = levelCenter;
result.SymbolLevels = symbolLevels;
result.CodeToSymbol = codeToSymbol;
result.LoopMean = loopMean;
result.ReferenceDecision = referenceDecision;
result.ReferenceMean = referenceMean;
result.SymmetricMean = symmetricMean;
result.SymmetricTransitionCount = symmetricTransitionCount;
result.CenteredPhaseOffsetSample = centeredPhaseOffsetSample;
result.CenteredPhaseOffsetUi = centeredPhaseOffsetUi;
result.CenteredReferenceMean = centeredReferenceMean;
result.CenteredSymmetricMean = centeredSymmetricMean;
result.CenteredLoopMean = centeredLoopMean;
result.NearestZeroPhase = nearestZeroPhase;
result.ZeroCrossingPhase = zeroCrossingPhase;
result.ZeroCrossingSlope = zeroCrossingSlope;
result.ReferenceZeroCrossingOffsetUi = referenceZeroCrossingOffsetUi;
result.ReferenceZeroCrossingSlope = referenceZeroCrossingSlope;
result.SymmetricZeroCrossingOffsetUi = symmetricZeroCrossingOffsetUi;
result.SymmetricZeroCrossingSlope = symmetricZeroCrossingSlope;
result.ReferenceOutput = referenceOutput;
result.ComparisonFigurePath = comparisonFigurePath;
result.CtleEyeStartUi = 0;
result.CtleEyeNumUi = eyeNumUi;
result.CtleEyeFigurePath = ctleEyeFigurePath;
result.UnitUiFigurePath = unitUiFigurePath;
result.HistogramFigurePath = histogramFigurePath;
resultMatPath = fullfile(resultDir, 'mmpd_s_curve_result.mat');
result.ResultMatPath = resultMatPath;
save(resultMatPath, 'result', '-v7.3');

fprintf(['MMPD S-curve (6-tap CDR FFE) passed: phases 0:127 used the same ' ...
    'UI range [%d,%d), nearest-zero phase %d.\n'], ...
    analysisStartUi, analysisStartUi + analysisNumUi, nearestZeroPhase);
fprintf('CDR FFE coefficients (pre..main..post): %s.\n', ...
    mat2str(cdrFfeCoefficients, 6));
fprintf('Classic MM zero crossings: %s.\n', mat2str(zeroCrossingPhase, 6));
fprintf('Fixed-decision zero crossings: %s.\n', ...
    mat2str(referenceZeroCrossingOffsetUi, 6));
fprintf('Symmetric-live zero crossings: %s.\n', ...
    mat2str(symmetricZeroCrossingOffsetUi, 6));
fprintf('Results saved to %s.\n', resultDir);
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

function [sampleAligned, decisionAligned] = alignFixedDecision( ...
    sample, decision, uiShift)
%ALIGNFIXEDDECISION Align a fixed decision sequence across a UI wrap.

if uiShift > 0
    sampleAligned = sample(1:end - uiShift);
    decisionAligned = decision(1 + uiShift:end);
elseif uiShift < 0
    sampleAligned = sample(1 - uiShift:end);
    decisionAligned = decision(1:end + uiShift);
else
    sampleAligned = sample;
    decisionAligned = decision;
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
