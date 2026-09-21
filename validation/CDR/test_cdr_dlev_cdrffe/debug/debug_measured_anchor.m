function debug_measured_anchor()
%DEBUG_MEASURED_ANCHOR Feasibility of a measured fixed anchor from smeared eye.
%   Proposal: before the loops run, measure the FIRST 200 blocks of raw ADC
%   codes at the (arbitrary) start phase - the eye is smeared there - and set
%   the fixed FFE-training anchor from label-free statistics:
%     recipe A: outerAnchor = 1.5   * mean(|x|)   (equiprobable PAM4, no ISI)
%     recipe B: outerAnchor = 3/sqrt(5) * std(x)  (power-based, ~1.342*std)
%   innerAnchor = outerAnchor/3.
%   Feasible iff the derived anchor stays inside the measured good basin
%   (outer ~[20,40], erring LOW is safe) for EVERY possible start phase.

thisFile = mfilename('fullpath');
testDir = fileparts(fileparts(thisFile));
addpath(testDir);
p = setup_cdr_dlev_cdrffe_paths('debug');
cdrValidationDir = p.CdrValidationDir;
validationDir = fileparts(cdrValidationDir);
repoRoot = p.RepoRoot;
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
numBlocks = 200;                          % = the proposed measurement window
segmentNumUi = baseUi + (numBlocks + 2) * adcBlockUi + 8;
segmentFirstSample = analysisStartUi * samplePerSymbol + 1;
segmentLastSample = (analysisStartUi + segmentNumUi) * samplePerSymbol;
ctleSegment = double(cacheFile.ctleOutput(1, segmentFirstSample:segmentLastSample));

phaseList = 0:samplePerSymbol - 1;
meanAbs = zeros(1, numel(phaseList));
stdX = zeros(1, numel(phaseList));
for pIdx = 1:numel(phaseList)
    x = sampleAtPhase(ctleSegment, phaseList(pIdx), numBlocks, baseUi, ...
        samplePerSymbol, nominalBlockLength, adcBlockUi, laneToTimeOrder, ...
        adcZeroCode, adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange);
    meanAbs(pIdx) = mean(abs(x));
    stdX(pIdx) = std(x);
end

outerA = 1.5 * meanAbs;
outerB = (3 / sqrt(5)) * stdX;
basinLo = 20; basinHi = 40;

fprintf('=== measured-anchor feasibility (200-block smeared-eye statistics) ===\n');
fprintf('phase  mean|x|  std(x) | outerA(1.5*mean|x|)  outerB(1.342*std)\n');
for pIdx = 1:8:numel(phaseList)
    fprintf('%4d   %6.2f  %6.2f |   %6.2f               %6.2f\n', ...
        phaseList(pIdx), meanAbs(pIdx), stdX(pIdx), outerA(pIdx), outerB(pIdx));
end
fprintf('--- summary over ALL 128 phases ---\n');
fprintf('recipe A outer anchor: min %.2f  median %.2f  max %.2f  (spread %.2f)\n', ...
    min(outerA), median(outerA), max(outerA), max(outerA) - min(outerA));
fprintf('recipe B outer anchor: min %.2f  median %.2f  max %.2f  (spread %.2f)\n', ...
    min(outerB), median(outerB), max(outerB), max(outerB) - min(outerB));
fprintf('good basin [%g, %g]: recipe A inside = %d/128 , recipe B inside = %d/128\n', ...
    basinLo, basinHi, sum(outerA >= basinLo & outerA <= basinHi), ...
    sum(outerB >= basinLo & outerB <= basinHi));
fprintf(['reference: eye-center truth outer 32.7 , converged dlev outer ~35.3 , ' ...
    'current default anchor 36\n']);

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 1000 480]);
hold on;
fill([phaseList fliplr(phaseList)], [basinLo * ones(1, 128), ...
    basinHi * ones(1, 128)], 'g', 'FaceAlpha', 0.10, 'EdgeColor', 'none');
plot(phaseList, outerA, 'b-', 'LineWidth', 1.5);
plot(phaseList, outerB, 'r-', 'LineWidth', 1.5);
yline(32.7, 'k--', 'eye-center outer 32.7');
yline(36, 'm:', 'current default 36');
hold off; grid on;
xlabel('start phase code (measurement phase)');
ylabel('derived outer anchor (code)');
legend('good basin [20,40]', 'recipe A: 1.5\cdotmean|x|', ...
    'recipe B: 1.342\cdotstd(x)', 'Location', 'best');
title('Measured fixed anchor vs (arbitrary) measurement phase, 200 blocks');
outPng = fullfile(testDir, 'result', 'cdr_dlev_cdrffe_sslms_v3', ...
    'debug_measured_anchor.png');
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
