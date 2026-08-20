function result = mmpd_cdr_live_scurve
%MMPD_CDR_LIVE_SCURVE Measure the live decision-directed MM S-curve.
%   Reuses the exact TI ADC + zero-forcing FFE + code->symbol calibration of
%   mmpd_Scurve_v2_cdr.m, then sweeps all 128 within-UI phases and evaluates
%   the LIVE decision-directed classic MM timing error (the detector the CDR
%   loop actually uses). This exposes false-lock zeros that the data-aided
%   reference S-curve hides. Saves a text dump and a PNG overlay of the live
%   and data-aided S-curves.

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(fileparts(fileparts(validationDir))));
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

waveformCsv = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', 'ctle_out.csv');
resultDir = fullfile(validationDir, 'results', 'mmpd_Scurve_v2');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

samplesPerUI = 128;
symbolRate = 56e9;
blockSize = 64;
startUi = 20;
numBits = 7;
adcLow = -0.45;
adcHigh = 0.45;
sarPerTah = 8;
inputMargin = samplesPerUI;
dataPhase = 78;
preTapCount = 6;
postTapCount = 10;

fixture = readmatrix(waveformCsv);
fixture = fixture(all(isfinite(fixture), 2), :);
time = fixture(:, 1).';
voltage = fixture(:, end).';

adc = ti_adc_top(blockSize, adcLow, adcHigh, numBits, sarPerTah, samplesPerUI);
adc.setInputMargin(inputMargin);
adc.resetState();

physicalLane = 1:blockSize;
phaseIndexLane = floor((physicalLane - 1) / sarPerTah) + 1;
sarIndexInPhase = mod(physicalLane - 1, sarPerTah) + 1;
timeOrderIndex = (sarIndexInPhase - 1) * (blockSize / sarPerTah) + phaseIndexLane;

nominalLength = (blockSize - 1) * samplesPerUI + 1;
maxFirstUi = floor((numel(voltage) - nominalLength - inputMargin - 1) / samplesPerUI);
numBlocks = floor((maxFirstUi - startUi) / blockSize) + 1;

localBlockMatrix = zeros(numBlocks, nominalLength + 2 * inputMargin);
codeMatrix = zeros(numBlocks, blockSize);
for blockIndex = 1:numBlocks
    firstUi = startUi + (blockIndex - 1) * blockSize;
    nominalStart = firstUi * samplesPerUI + 1;
    localStart = nominalStart - inputMargin;
    localStop = nominalStart + nominalLength - 1 + inputMargin;
    localWaveform = voltage(localStart:localStop);
    localBlockMatrix(blockIndex, :) = localWaveform;

    physicalCode = adc.convertOneBlockFast(localWaveform, dataPhase + 1);
    codeBlock = zeros(1, blockSize);
    codeBlock(timeOrderIndex) = physicalCode;
    codeMatrix(blockIndex, :) = codeBlock;
end

codeStream = reshape(codeMatrix.', 1, []);

codeCenter = estimatePam4Centers(double(codeStream));
codeThreshold = (codeCenter(1:3) + codeCenter(2:4)) / 2;
symbolLevelStream = double(codeStream > codeThreshold(1)) + ...
    double(codeStream > codeThreshold(2)) + ...
    double(codeStream > codeThreshold(3));
symbol = 2 * symbolLevelStream - 3;

received = double(codeStream) - mean(double(codeStream));
symbolPower = mean(symbol .^ 2);

lagRange = -(preTapCount + 3):(postTapCount + 3);
pulse = zeros(1, numel(lagRange));
for lagIndex = 1:numel(lagRange)
    lag = lagRange(lagIndex);
    n = max(1, 1 + lag):min(numel(received), numel(received) + lag);
    pulse(lagIndex) = mean(received(n) .* symbol(n - lag)) / symbolPower;
end
[~, mainLagIndex] = max(abs(pulse));
pulse = pulse / pulse(mainLagIndex);
mainLag = lagRange(mainLagIndex);

targetCursor = 0.1;
tapDelays = (-preTapCount):postTapCount;
freeDelays = tapDelays(tapDelays ~= 0);
pAt = @(k) getPulse(pulse, lagRange, mainLag, k);

controlCursors = freeDelays;
targetResponse = zeros(numel(controlCursors), 1);
targetResponse(controlCursors == -1) = targetCursor;
targetResponse(controlCursors == 1) = targetCursor;

A = zeros(numel(controlCursors), numel(freeDelays));
b = zeros(numel(controlCursors), 1);
for row = 1:numel(controlCursors)
    m = controlCursors(row);
    for col = 1:numel(freeDelays)
        A(row, col) = pAt(m - freeDelays(col));
    end
    b(row) = targetResponse(row) - pAt(m);
end
freeTaps = (A \ b).';

coefficients = zeros(1, numel(tapDelays));
coefficients(tapDelays == 0) = 1;
coefficients(tapDelays ~= 0) = freeTaps;

ffe = cdr_ffe(coefficients, preTapCount);
[ffeOutput, ~, validOutput] = ffe.processBlock(codeStream);
ffeValid = ffeOutput(validOutput);

symbolLevels = [-3 -1 1 3];
ffeCenter = estimatePam4Centers(ffeValid);
symbolMap = polyfit(ffeCenter, symbolLevels, 1);
codeToSymbol = @(x) symbolMap(1) * x + symbolMap(2);

% Data-aided reference symbols (eye-center decisions, fixed).
referenceLevel = codeToSymbol(ffeValid);
[~, referenceIndex] = min(abs(referenceLevel(:) - symbolLevels), [], 2);
referenceSymbol = reshape(symbolLevels(referenceIndex), 1, []);

% --- Sweep all 128 phases, compute BOTH detectors ------------------------
phaseList = 0:(samplesPerUI - 1);
liveScurve = zeros(1, numel(phaseList));
daScurve = zeros(1, numel(phaseList));
for phaseIdx = 1:numel(phaseList)
    phi = phaseList(phaseIdx);
    codeMatrixPhi = zeros(numBlocks, blockSize);
    for blockIndex = 1:numBlocks
        localWaveform = localBlockMatrix(blockIndex, :);
        physicalCode = adc.convertOneBlockFast(localWaveform, phi + 1);
        codeBlock = zeros(1, blockSize);
        codeBlock(timeOrderIndex) = physicalCode;
        codeMatrixPhi(blockIndex, :) = codeBlock;
    end
    codeStreamPhi = reshape(codeMatrixPhi.', 1, []);

    ffePhi = cdr_ffe(coefficients, preTapCount);
    [ffeOutputPhi, ~, validOutputPhi] = ffePhi.processBlock(codeStreamPhi);
    ffeValidPhi = ffeOutputPhi(validOutputPhi);

    sampled = codeToSymbol(ffeValidPhi);

    % Data-aided error (fixed eye-center decisions).
    slicerErrorDa = sampled - referenceSymbol;
    timingDa = referenceSymbol(1:end - 1) .* slicerErrorDa(2:end) - ...
        referenceSymbol(2:end) .* slicerErrorDa(1:end - 1);
    daScurve(phaseIdx) = mean(timingDa);

    % Live decision-directed error (decisions re-made at this phase).
    [~, di] = min(abs(sampled(:) - symbolLevels), [], 2);
    decision = reshape(symbolLevels(di), 1, []);
    slicerErrorLive = sampled - decision;
    timingLive = decision(1:end - 1) .* slicerErrorLive(2:end) - ...
        decision(2:end) .* slicerErrorLive(1:end - 1);
    liveScurve(phaseIdx) = mean(timingLive);
end

% Locate zero crossings of the live S-curve (on the phase-index axis).
liveZeros = [];
for k = 1:samplesPerUI
    kNext = mod(k, samplesPerUI) + 1;
    y1 = liveScurve(k);
    y2 = liveScurve(kNext);
    if y1 == 0
        liveZeros(end + 1) = phaseList(k); %#ok<AGROW>
    elseif y1 * y2 < 0
        slope = y2 - y1;
        stable = slope < 0;   % negative slope with errorSign=+1 => stable
        cross = phaseList(k) - y1 / slope;
        liveZeros(end + 1) = cross; %#ok<AGROW>
        fprintf('live zero near index %6.2f  slope %+8.4f  %s\n', ...
            cross, slope, ternary(stable, 'STABLE', 'unstable'));
    end
end

% --- Save dump and plot --------------------------------------------------
dumpPath = fullfile(resultDir, 'mmpd_cdr_live_scurve.txt');
fid = fopen(dumpPath, 'w');
fprintf(fid, ' idx      live      data-aided\n');
for k = 1:samplesPerUI
    fprintf(fid, '%4d  %+9.4f  %+9.4f\n', phaseList(k), liveScurve(k), daScurve(k));
end
fclose(fid);

figLive = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 500]);
plot(phaseList, liveScurve, '-o', 'MarkerSize', 3, 'LineWidth', 1.3, ...
    'Color', [0.85 0.33 0.10]);
hold on;
plot(phaseList, daScurve, '-', 'LineWidth', 1.3, 'Color', [0.20 0.45 0.75]);
yline(0, 'k-', 'LineWidth', 0.5);
xline(dataPhase, 'k:', 'LineWidth', 0.8);
grid on;
xlabel('Sampling phase index (0..127)');
ylabel('Mean MM timing error');
legend({'live decision-directed', 'data-aided reference'}, 'Location', 'best');
title('Live vs data-aided MM S-curve (eye center index 78)');
xlim([0 127]);
plotPath = fullfile(resultDir, 'mmpd_cdr_live_scurve.png');
exportgraphics(figLive, plotPath, 'Resolution', 200);
close(figLive);

fprintf('Live S-curve zeros (index): %s\n', mat2str(round(liveZeros * 100) / 100));
fprintf('Saved dump : %s\n', dumpPath);
fprintf('Saved plot : %s\n', plotPath);

result = struct();
result.PhaseList = phaseList;
result.LiveScurve = liveScurve;
result.DataAidedScurve = daScurve;
result.LiveZeros = liveZeros;
result.DumpPath = dumpPath;
result.PlotPath = plotPath;
end

function out = ternary(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end

function value = getPulse(pulse, lagRange, mainLag, cursor)
%GETPULSE Return the pulse sample at a cursor offset from the main cursor.
targetLag = cursor + mainLag;
idx = find(lagRange == targetLag, 1);
if isempty(idx)
    value = 0;
else
    value = pulse(idx);
end
end

function center = estimatePam4Centers(sample)
%ESTIMATEPAM4CENTERS Toolbox-free 1-D k-means PAM4 level estimate.
center = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    distance = abs(sample(:) - center);
    [~, clusterIndex] = min(distance, [], 2);
    updatedCenter = center;
    for levelIndex = 1:4
        levelSample = sample(clusterIndex == levelIndex);
        assert(~isempty(levelSample), 'PAM4 code clustering produced an empty level.');
        updatedCenter(levelIndex) = mean(levelSample);
    end
    updatedCenter = sort(updatedCenter);
    if max(abs(updatedCenter - center)) < 1e-12
        center = updatedCenter;
        break;
    end
    center = updatedCenter;
end
end
