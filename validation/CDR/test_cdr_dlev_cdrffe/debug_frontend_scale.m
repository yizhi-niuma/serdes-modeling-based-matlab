function debug_frontend_scale()
%DEBUG_FRONTEND_SCALE Measure the a-priori front-end PAM4 code scale.
%   Establishes whether the dlev anchor (DlevOuterInit/DlevInnerInit) is a
%   value knowable BEFORE the CDR loop runs (a front-end / AGC nominal) or
%   whether it is the CDR convergence answer fed back. Runs the ADC only
%   (no FFE adaptation, no dlev loop, no CDR loop) over the cached Channel+CTLE
%   waveform and extracts the four PAM4 cluster levels in ADC-code domain,
%   swept across all 128 sampling phases so the phase dependence is visible.

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
numBlocks = 120;                       % ~7680 symbols
segmentNumUi = baseUi + (numBlocks + 2) * adcBlockUi + 8;
segmentFirstSample = analysisStartUi * samplePerSymbol + 1;
segmentLastSample = (analysisStartUi + segmentNumUi) * samplePerSymbol;
ctleSegment = double(cacheFile.ctleOutput(1, segmentFirstSample:segmentLastSample));

phaseList = 0:samplePerSymbol - 1;
outerByPhase = zeros(1, samplePerSymbol);
innerByPhase = zeros(1, samplePerSymbol);

for pIdx = 1:numel(phaseList)
    phase = phaseList(pIdx);
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
    % PAM4 four-cluster levels straight from the raw ADC codes: no loop, no FFE.
    pos = codeStream(codeStream > 0);
    neg = -codeStream(codeStream < 0);
    posMed = median(pos);
    negMed = median(neg);
    outerByPhase(pIdx) = mean([pos(pos >= posMed), neg(neg >= negMed)]);
    innerByPhase(pIdx) = mean([pos(pos < posMed), neg(neg < negMed)]);
end

[bestOuterOpen, bestPhase] = max(outerByPhase - innerByPhase);
fprintf('=== A-priori front-end PAM4 code scale (raw ADC, NO FFE/dlev/CDR loop) ===\n');
fprintf('phase  outer  inner  ratio\n');
for pIdx = 1:8:numel(phaseList)
    fprintf('%4d  %6.2f %6.2f  %5.2f\n', phaseList(pIdx), ...
        outerByPhase(pIdx), innerByPhase(pIdx), ...
        outerByPhase(pIdx) / max(innerByPhase(pIdx), eps));
end
fprintf('--- summary over all 128 phases ---\n');
fprintf('outer: min %.2f  median %.2f  max %.2f\n', ...
    min(outerByPhase), median(outerByPhase), max(outerByPhase));
fprintf('inner: min %.2f  median %.2f  max %.2f\n', ...
    min(innerByPhase), median(innerByPhase), max(innerByPhase));
fprintf('best-opening phase %d: outer %.2f inner %.2f (ratio %.2f)\n', ...
    phaseList(bestPhase), outerByPhase(bestPhase), innerByPhase(bestPhase), ...
    outerByPhase(bestPhase) / innerByPhase(bestPhase));
fprintf('current no-arg anchor = outer 36 / inner 12 (ratio 3.00)\n');

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 950 520]);
plot(phaseList, outerByPhase, 'b-', 'LineWidth', 1.4); hold on;
plot(phaseList, innerByPhase, 'r-', 'LineWidth', 1.4);
yline(36, 'b--', 'anchor outer 36');
yline(12, 'r--', 'anchor inner 12');
hold off; grid on;
xlabel('sampling phase code'); ylabel('raw ADC |code| cluster level');
legend('outer (raw ADC)', 'inner (raw ADC)', 'Location', 'best');
title('A-priori front-end PAM4 code scale vs phase (no FFE / no loop)');
outPng = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms_v3', ...
    'debug_frontend_scale.png');
exportgraphics(fig, outPng, 'Resolution', 150);
close(fig);
fprintf('figure saved to %s\n', outPng);
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
