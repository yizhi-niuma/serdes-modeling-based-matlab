function debug_v3_scurve(resultMatOverride, phaseIdxList, blockList)
%DEBUG_V3_SCURVE Offline SS-MMPD S-curve vs phase for frozen FFE/dlev states.
%   Diagnostic for cdr_dlev_cdrffe_sslms_v3 slow phase glide: sweep all 128
%   sampling phases with the FFE taps / dlev levels frozen at selected
%   (phaseIdx, block) states of a saved result. Shows how the S-curve zero
%   moves as the FFE relaxes, and whether a usable negative-slope zero exists
%   once the FFE is quasi-static.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
cdrValidationDir = fileparts(testDir);
validationDir = fileparts(cdrValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

resultMat = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms_v3', ...
    'cdr_dlev_cdrffe_sslms_v3_result.mat');
if nargin >= 1 && ~isempty(resultMatOverride)
    resultMat = resultMatOverride;
end
loaded = load(resultMat);
if isfield(loaded, 'result')
    r = loaded.result;
else
    r = loaded.r;
end
if nargin < 2 || isempty(phaseIdxList)
    phaseIdxList = [1 1];
end
if nargin < 3 || isempty(blockList)
    blockList = [500 8000];
end

cachePath = fullfile(cdrValidationDir, 'test_cdr', 'result', ...
    'channel_ctle_cosim', 'channel_ctle.mat');
cacheFile = matfile(cachePath);
samplePerSymbol = double(cacheFile.samplePerSymbol);

adcLaneCount = 64;
adcSarPerTah = 8;
adcResolutionBits = 7;
adcFullRange = 4;
adcZeroCode = 2^(adcResolutionBits - 1);
adcBlockUi = 64;
cdrFfePreTapCount = 2;
cdrFfePostTapCount = 3;
[laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol);

% Short segment: baseUi guard + numBlocks*64 + one block + guard.
analysisStartUi = 512;
baseUi = 256;
numBlocks = 100;
segmentNumUi = baseUi + (numBlocks + 2) * adcBlockUi + 8;
segmentFirstSample = analysisStartUi * samplePerSymbol + 1;
segmentLastSample = (analysisStartUi + segmentNumUi) * samplePerSymbol;
ctleSegment = double(cacheFile.ctleOutput(1, segmentFirstSample:segmentLastSample));

phaseIdx = 1;                               %#ok<NASGU> % legacy
stateBlocks = blockList;
stateName = cell(1, numel(stateBlocks));
for s = 1:numel(stateBlocks)
    stateName{s} = sprintf('idx%d-block%d', phaseIdxList(s), stateBlocks(s));
end

meanCurve = zeros(numel(stateBlocks), samplePerSymbol);
validCurve = zeros(numel(stateBlocks), samplePerSymbol);

for s = 1:numel(stateBlocks)
    b = stateBlocks(s);
    phaseIdx = phaseIdxList(s);
    taps = reshape(r.FfeCoeffTrace(phaseIdx, b, :), 1, []);
    dlevInner = r.DlevInnerTrace(phaseIdx, b);
    dlevOuter = r.DlevOuterTrace(phaseIdx, b);
    threshold = (dlevInner + dlevOuter) / 2;
    fprintf('[%s] taps=[%s], dlev=[%.3f %.3f], thr=%.3f\n', stateName{s}, ...
        strtrim(sprintf('%+.4f ', taps)), dlevInner, dlevOuter, threshold);

    for phase = 0:samplePerSymbol - 1
        adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
            adcResolutionBits, adcSarPerTah, samplePerSymbol);
        adcModel.setInputMargin(0);
        codeStream = zeros(1, numBlocks * adcBlockUi);
        for blockIndex = 1:numBlocks
            firstUi = baseUi + (blockIndex - 1) * adcBlockUi;
            blockStart = firstUi * samplePerSymbol + phase + 1;
            blockStop = blockStart + nominalBlockLength - 1;
            physicalCode = adcModel.convertOneBlockFast( ...
                ctleSegment(blockStart:blockStop), 1);
            codeStream((blockIndex - 1) * adcBlockUi + (1:adcBlockUi)) = ...
                double(physicalCode(laneToTimeOrder)) - adcZeroCode;
        end
        ffeModel = cdr_ffe([0 0 1 0 0 0], cdrFfePreTapCount);
        ffeModel.applyCoefficientDelta(taps - [0 0 1 0 0 0]);
        inputWindow = [zeros(1, cdrFfePostTapCount), codeStream, ...
            zeros(1, cdrFfePreTapCount)];
        outputBlock = ffeModel.processBlock(inputWindow);
        valid = true(1, numel(outputBlock));
        valid(1:cdrFfePostTapCount) = false;
        valid(end - cdrFfePreTapCount + 1:end) = false;
        x = outputBlock(valid);

        % Single slicer identical to sliceCodePam4.
        isNegative = x < 0;
        isOuter = abs(x) >= threshold;
        magnitude = dlevInner + (dlevOuter - dlevInner) .* isOuter;
        decision = magnitude;
        decision(isNegative) = -magnitude(isNegative);
        sliceError = x - decision;

        ssIsPositive = decision >= 0;
        ssIsOuter = abs(decision) >= threshold;
        ssDataSymbol = double(ssIsPositive) * 2 + double(ssIsPositive == ssIsOuter);
        ssErrorBit = double(sliceError >= 0);

        dataPrev = ssDataSymbol(1:end - 1);
        dataCurr = ssDataSymbol(2:end);
        errorPrev = ssErrorBit(1:end - 1);
        errorCurr = ssErrorBit(2:end);

        sameError = errorPrev == errorCurr;
        errorHigh = errorPrev ~= 0;
        dataTransition = dataPrev ~= dataCurr;
        risingTransition = dataCurr > dataPrev;
        validT = sameError & dataTransition;
        early = validT & ((~risingTransition & errorHigh) | ...
            (risingTransition & ~errorHigh));
        dec = zeros(size(validT));
        dec(validT) = -1;
        dec(early) = 1;

        meanCurve(s, phase + 1) = mean(dec);
        validCurve(s, phase + 1) = mean(validT);
    end
end

phaseAxis = 0:samplePerSymbol - 1;
% Loop-applied PD bias: meanPhaseError = mean(ssDecision) + pdOffset*biasActive,
% biasActive = codeWrapped in [biasLo, biasHi]. This is the mechanism that pushes
% the mid-UI region below zero to kill the two weak parasitic lock points.
pdOffset = -0.05;
biasLo = 45;
biasHi = 116;
biasMask = (phaseAxis >= biasLo) & (phaseAxis <= biasHi);
biasedCurve = meanCurve + pdOffset .* biasMask;

for s = 1:numel(stateBlocks)
    for variant = 1:2
        if variant == 1
            c = meanCurve(s, :);
            tag = 'RAW (no PD bias)';
        else
            c = biasedCurve(s, :);
            tag = sprintf('LOOP (with pdOffset %.2f in [%d,%d])', ...
                pdOffset, biasLo, biasHi);
        end
        fprintf('\n[%s] %s S-curve:\n', stateName{s}, tag);
        for p = 1:8:samplePerSymbol
            fprintf('  ph %3d..%3d :', p - 1, p + 6);
            fprintf(' %+7.3f', c(p:p + 7));
            fprintf('\n');
        end
        % zero crossings (linear interp between adjacent phases, circular)
        cNext = c([2:end 1]);
        crossing = find(c .* cNext < 0);
        fprintf('  zero crossings (neg-slope = stable lock):');
        for k = crossing
            frac = c(k) / (c(k) - cNext(k));
            slope = cNext(k) - c(k);
            stab = '';
            if slope < 0, stab = '*STABLE*'; end
            fprintf(' %.2f(slope %+0.4f)%s', phaseAxis(k) + frac, slope, stab);
        end
        fprintf('\n');
    end
    fprintf('  valid density: min %.3f mean %.3f\n', ...
        min(validCurve(s, :)), mean(validCurve(s, :)));
end

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 1100 650]);
plot(phaseAxis, meanCurve(1, :), 'b--', 'LineWidth', 1.0);
hold on;
plot(phaseAxis, biasedCurve(1, :), 'b-', 'LineWidth', 1.6);
plot(phaseAxis, meanCurve(2, :), 'r--', 'LineWidth', 1.0);
plot(phaseAxis, biasedCurve(2, :), 'r-', 'LineWidth', 1.6);
yline(0, 'k-');
xline(biasLo, 'm:', sprintf('bias zone %d', biasLo));
xline(biasHi, 'm:', sprintf('bias zone %d', biasHi));
hold off;
grid on;
legend([stateName{1} ' raw'], [stateName{1} ' loop'], ...
    [stateName{2} ' raw'], [stateName{2} ' loop'], 'Location', 'best');
xlabel('Sampling phase code');
ylabel('mean SS-MMPD decision (loop S-curve)');
title(sprintf(['SS-MMPD S-curve: raw vs loop (pdOffset %.2f gated to [%d,%d]) ' ...
    '- solid = what the phase loop sees'], pdOffset, biasLo, biasHi));
outPng = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms_v3', ...
    'debug_scurve_frozen_states.png');
exportgraphics(fig, outPng, 'Resolution', 150);
close(fig);
fprintf('\nS-curve figure saved to %s\n', outPng);
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
