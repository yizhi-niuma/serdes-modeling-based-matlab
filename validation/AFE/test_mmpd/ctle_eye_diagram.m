%% mmpd_Scurve_v1 - CTLE output eye diagram via maximum-eye-opening centering.
%   Reads the CTLE output waveform CSV, discards the leading delay/settling
%   section, locates the sampling phase that maximizes the PAM4 eye opening,
%   and plots a two-UI eye diagram aligned to that eye center.
%
%   Data format: two-column CSV, column 1 = time (s), column 2 = amplitude.
%   Signal model: 56 GBd PAM4 (four levels), matching the AFE co-simulation.

clear; close all; clc;

%% ==================== User parameters ====================
mat_path = 'C:\Work\MatLab_Lib\data\ADC\TI_ADC\ctle_out.mat';
outputDir = 'C:\Work\MatLab_Lib\validation\AFE\test_mmpd';
symbolRate = 56e9;      % Baud rate (Hz); UI = 1 / symbolRate.
numLevels = 4;          % PAM4 has four amplitude levels.
settleUi = 20;          % Extra UIs skipped after the first active edge.
uiOverride = [];        % Set a UI in seconds to bypass symbolRate.
eyeTraceLimit = 4000;   % Maximum number of two-UI traces drawn.

%% ==================== Read data ====================
fprintf('Reading waveform: %s\n', mat_path);
load(mat_path);
timeAxis = time;
waveform = amplitude;
timeAxis = timeAxis(:);
waveform = waveform(:);
sampleInterval = median(diff(timeAxis));
fprintf('Samples = %d, dt = %.6g s, Fs = %.6g Hz\n', ...
    numel(waveform), sampleInterval, 1 / sampleInterval);

%% ==================== Derive samples per UI ====================
if isempty(uiOverride)
    unitInterval = 1 / symbolRate;
else
    unitInterval = uiOverride;
end
samplePerSymbol = round(unitInterval / sampleInterval);
assert(samplePerSymbol >= 8, ...
    'Samples per UI too small; check symbolRate or uiOverride.');
fprintf('UI = %.6g s (%.4g GBd), samples per UI = %d\n', ...
    unitInterval, symbolRate / 1e9, samplePerSymbol);

%% ==================== Remove leading delay/settling ====================
referenceLevel = median(waveform);
swing = prctile(waveform, 99) - prctile(waveform, 1);
firstActive = find(abs(waveform - referenceLevel) > 0.15 * swing, 1, 'first');
if isempty(firstActive)
    firstActive = 1;
end
startIndex = min(firstActive + settleUi * samplePerSymbol, numel(waveform));
waveform = waveform(startIndex:end);
timeAxis = timeAxis(startIndex:end);
fprintf('Discarded leading %d samples (%.6g s)\n', ...
    startIndex - 1, (startIndex - 1) * sampleInterval);

%% ==================== Maximum-eye-opening phase search ====================
numUi = floor(numel(waveform) / samplePerSymbol);
assert(numUi > 20, 'Too few UIs remain after trimming.');
folded = reshape(waveform(1:numUi * samplePerSymbol), ...
    samplePerSymbol, numUi).';

phaseOpening = zeros(samplePerSymbol, 1);
for phase = 1:samplePerSymbol
    phaseOpening(phase) = min(computeEyeOpening(folded(:, phase), numLevels));
end
[maxOpening, centerPhase] = max(phaseOpening);
[eyeOpenings, levelCenters] = computeEyeOpening( ...
    folded(:, centerPhase), numLevels);
centerFractionUi = (centerPhase - 1) / samplePerSymbol;
fprintf('Eye-center phase column = %d / %d (%.4f UI, %.6g s)\n', ...
    centerPhase, samplePerSymbol, centerFractionUi, ...
    (centerPhase - 1) * sampleInterval);
fprintf('Minimum eye opening = %.6g, per-eye openings = %s\n', ...
    maxOpening, mat2str(eyeOpenings, 4));
fprintf('Level centers = %s\n', mat2str(levelCenters, 4));

%% ==================== Plot two-UI eye diagram ====================
if ~exist(outputDir, 'dir')
    mkdir(outputDir);
end
eyeTime = ((0:2 * samplePerSymbol - 1) - samplePerSymbol) / samplePerSymbol;
firstCenter = centerPhase + samplePerSymbol;
traceStarts = firstCenter : samplePerSymbol : (numel(waveform) - samplePerSymbol);
if numel(traceStarts) > eyeTraceLimit
    traceStarts = traceStarts(round(linspace(1, numel(traceStarts), eyeTraceLimit)));
end

figureHandle = figure('Color', 'w', 'Position', [100 100 900 600]);
hold on;
for center = traceStarts
    windowIndex = (center - samplePerSymbol):(center + samplePerSymbol - 1);
    if windowIndex(1) < 1 || windowIndex(end) > numel(waveform)
        continue;
    end
    plot(eyeTime, waveform(windowIndex), 'Color', [0 0.35 0.75 0.06]);
end
xline(0, 'r--', 'Eye center', 'LineWidth', 1.4, ...
    'LabelVerticalAlignment', 'bottom');
for levelIndex = 1:numLevels
    yline(levelCenters(levelIndex), 'k:');
end
hold off;
grid on;
xlim([-1 1]);
xlabel('Time (UI)');
ylabel('Amplitude');
title(sprintf(['CTLE Output Eye (2 UI, max-eye-opening center): ' ...
    'phase %d/%d, min opening %.4g'], ...
    centerPhase, samplePerSymbol, maxOpening));

eyeFigurePath = fullfile(outputDir, 'ctle_out_eye_2ui.png');
exportgraphics(figureHandle, eyeFigurePath, 'Resolution', 150);
fprintf('Eye diagram saved: %s\n', eyeFigurePath);

%% ==================== Local functions ====================
function [openings, levelCenters] = computeEyeOpening(sample, numLevels)
%COMPUTEEYEOPENING Cluster phase samples into levels and measure eye openings.
%   Returns the per-eye vertical openings (numLevels-1 values) and the
%   estimated level centers. A one-dimensional k-means (no toolbox) groups
%   the samples; each eye opening is the gap between the upper level's low
%   tail and the lower level's high tail.

sample = sample(:);
initQuantile = (2 * (1:numLevels) - 1) / (2 * numLevels);
levelCenters = prctile(sample, 100 * initQuantile).';
for iteration = 1:20
    distance = abs(sample - levelCenters(:).');
    [~, assignment] = min(distance, [], 2);
    updated = levelCenters;
    for levelIndex = 1:numLevels
        clusterSample = sample(assignment == levelIndex);
        if ~isempty(clusterSample)
            updated(levelIndex) = mean(clusterSample);
        end
    end
    if max(abs(updated - levelCenters)) < eps(max(abs(sample)))
        levelCenters = updated;
        break;
    end
    levelCenters = updated;
end
levelCenters = sort(levelCenters(:).');

openings = zeros(1, numLevels - 1);
distance = abs(sample - levelCenters(:).');
[~, assignment] = min(distance, [], 2);
for eyeIndex = 1:numLevels - 1
    lowerSample = sample(assignment == eyeIndex);
    upperSample = sample(assignment == eyeIndex + 1);
    if isempty(lowerSample) || isempty(upperSample)
        openings(eyeIndex) = 0;
    else
        openings(eyeIndex) = prctile(upperSample, 5) - prctile(lowerSample, 95);
    end
end
end
