function debug_eye_vs_phase()
%DEBUG_EYE_VS_PHASE Golden-labeled phase-dependent PAM4 eye (raw ADC, no loops).
%   Fixes the earlier flawed metrics:
%     - median/quartile split measures only CLUSTER MEANS (phase-flat because
%       ISI is zero-mean) OR manufactures 4 groups from any distribution and so
%       CANNOT detect eye closure.
%   Correct method: label every sampled UI with its TRUE transmitted symbol
%   (integer UI delay estimated by cross-correlation), split into the 4 real
%   PAM4 levels, and report each level's mean AND std (= ISI spread) plus the
%   true min eye opening = min adjacent (mean_hi - std_hi) - (mean_lo + std_lo).

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
cdrValidationDir = fileparts(testDir);
validationDir = fileparts(cdrValidationDir);
repoRoot = fileparts(validationDir);
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));

cachePath = fullfile(cdrValidationDir, 'test_cdr', 'result', ...
    'channel_ctle_cosim', 'channel_ctle.mat');
cacheFile = matfile(cachePath);
samplePerSymbol = double(cacheFile.samplePerSymbol);
txPam4Symbols = double(cacheFile.pam4Symbols);      % 1 per UI

adcLaneCount = 64;
adcSarPerTah = 8;
adcResolutionBits = 7;
adcFullRange = 4;
adcZeroCode = 2^(adcResolutionBits - 1);
adcBlockUi = 64;
[laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol);

analysisStartUi = 512;
baseUi = 256;
numBlocks = 120;
segmentNumUi = baseUi + (numBlocks + 2) * adcBlockUi + 8;
segmentFirstSample = analysisStartUi * samplePerSymbol + 1;
segmentLastSample = (analysisStartUi + segmentNumUi) * samplePerSymbol;
ctleSegment = double(cacheFile.ctleOutput(1, segmentFirstSample:segmentLastSample));

% Absolute UI index (1-based into txPam4Symbols) for each collected code.
kCount = numBlocks * adcBlockUi;
uiIndex = zeros(1, kCount);
for b = 1:numBlocks
    firstUi = baseUi + (b - 1) * adcBlockUi;
    uiIndex((b - 1) * adcBlockUi + (1:adcBlockUi)) = ...
        analysisStartUi + firstUi + (0:adcBlockUi - 1) + 1;
end

% ---- estimate integer UI main-cursor delay: scan phases, take global peak ----
% (estimating at a closed-eye phase gives an ambiguous peak; scan and pick the
%  phase+lag with the strongest correlation, which lands on an open-eye phase.)
maxLag = 160;
bestCorr = -inf; mainCursorUi = 0;
for phase = 0:8:samplePerSymbol - 1
    cs = sampleAtPhase(ctleSegment, phase, numBlocks, baseUi, samplePerSymbol, ...
        nominalBlockLength, adcBlockUi, laneToTimeOrder, adcZeroCode, ...
        adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange);
    for d = 90:120
        c = abs(sum(cs .* txPam4Symbols(uiIndex - d)));
        if c > bestCorr, bestCorr = c; mainCursorUi = d; end
    end
end
fprintf('estimated main-cursor UI delay = %d\n', mainCursorUi);

% Group by the 4 true transmitted levels directly (no sign/median assumption).
uniqueLevels = unique(txPam4Symbols);       % ascending: [-outer -inner +inner +outer]
assert(numel(uniqueLevels) == 4, 'expected 4 PAM4 levels, got %d', numel(uniqueLevels));
txLabel = txPam4Symbols(uiIndex - mainCursorUi);

phaseList = 0:samplePerSymbol - 1;
lvlMean = zeros(samplePerSymbol, 4);   % [-outer -inner +inner +outer]
lvlStd = zeros(samplePerSymbol, 4);
minOpening = zeros(1, samplePerSymbol);

for pIdx = 1:numel(phaseList)
    phase = phaseList(pIdx);
    codeStream = sampleAtPhase(ctleSegment, phase, numBlocks, baseUi, ...
        samplePerSymbol, nominalBlockLength, adcBlockUi, laneToTimeOrder, ...
        adcZeroCode, adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange);
    for g = 1:4
        seg = codeStream(txLabel == uniqueLevels(g));
        lvlMean(pIdx, g) = mean(seg);
        lvlStd(pIdx, g) = std(seg);
    end
    op = zeros(1, 3);
    for e = 1:3
        op(e) = (lvlMean(pIdx, e + 1) - lvlStd(pIdx, e + 1)) - ...
            (lvlMean(pIdx, e) + lvlStd(pIdx, e));
    end
    minOpening(pIdx) = min(op);
end

outerPos = lvlMean(:, 4).';
[bestOpen, bestIdx] = max(minOpening);
[worstOpen, worstIdx] = min(minOpening);
fprintf('=== Golden-labeled PAM4 eye vs phase (raw ADC, no FFE/loop) ===\n');
fprintf('phase  +outer(std)  +inner(std)  minEyeOpen(1sigma)\n');
for pIdx = 1:8:numel(phaseList)
    fprintf('%4d  %5.1f(%4.1f) %5.1f(%4.1f)  %+7.1f\n', phaseList(pIdx), ...
        lvlMean(pIdx, 4), lvlStd(pIdx, 4), lvlMean(pIdx, 3), lvlStd(pIdx, 3), ...
        minOpening(pIdx));
end
fprintf('--- summary ---\n');
fprintf('+outer mean: %.1f..%.1f (%.1f%% variation)\n', ...
    min(outerPos), max(outerPos), 100 * (max(outerPos) - min(outerPos)) / mean(outerPos));
fprintf('min-eye-opening: BEST %+.1f @phase %d ; WORST %+.1f @phase %d\n', ...
    bestOpen, phaseList(bestIdx), worstOpen, phaseList(worstIdx));
nClosed = sum(minOpening <= 0);
fprintf('phases with CLOSED eye (opening<=0): %d / %d\n', nClosed, samplePerSymbol);

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 1000 640]);
subplot(2, 1, 1);
plot(phaseList, lvlMean(:, 4), 'b-', 'LineWidth', 1.3); hold on;
plot(phaseList, lvlMean(:, 3), 'c-', 'LineWidth', 1.3);
plot(phaseList, lvlMean(:, 2), 'm-', 'LineWidth', 1.3);
plot(phaseList, lvlMean(:, 1), 'r-', 'LineWidth', 1.3);
for g = 1:4
    fill([phaseList fliplr(phaseList)], ...
        [lvlMean(:, g).' + lvlStd(:, g).', fliplr(lvlMean(:, g).' - lvlStd(:, g).')], ...
        'k', 'FaceAlpha', 0.08, 'EdgeColor', 'none');
end
hold off; grid on; ylabel('ADC code');
legend('+outer', '+inner', '-inner', '-outer', 'Location', 'eastoutside');
title('True 4-level clusters \pm1\sigma vs phase (golden-labeled, raw ADC)');
subplot(2, 1, 2);
plot(phaseList, minOpening, 'k-', 'LineWidth', 1.5); hold on;
yline(0, 'r--', 'closed'); hold off; grid on;
xlabel('sampling phase code'); ylabel('min eye opening (code, 1\sigma)');
title('True min PAM4 eye opening vs phase');
outPng = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms_v3', ...
    'debug_eye_vs_phase.png');
exportgraphics(fig, outPng, 'Resolution', 150);
close(fig);
fprintf('figure saved to %s\n', outPng);
end

function codeStream = sampleAtPhase(ctleSegment, phase, numBlocks, baseUi, ...
    samplePerSymbol, nominalBlockLength, adcBlockUi, laneToTimeOrder, ...
    adcZeroCode, adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange)
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
codeStream = zeros(1, numBlocks * adcBlockUi);
for b = 1:numBlocks
    firstUi = baseUi + (b - 1) * adcBlockUi;
    blockStart = firstUi * samplePerSymbol + phase + 1;
    blockStop = blockStart + nominalBlockLength - 1;
    physicalCode = adcModel.convertOneBlockFast(ctleSegment(blockStart:blockStop), 1);
    codeStream((b - 1) * adcBlockUi + (1:adcBlockUi)) = ...
        double(physicalCode(laneToTimeOrder)) - adcZeroCode;
end
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
