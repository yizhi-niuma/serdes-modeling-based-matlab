function result = mmpd_Scurve_v2_cdr_transition_filtering
%MMPD_SCURVE_V2_CDR_TRANSITION_FILTERING Transition-filtered live MM S-curve.
%   Reuses the exact TI ADC + zero-forcing FFE + code->symbol calibration of
%   mmpd_Scurve_v2_cdr.m / mmpd_cdr_live_scurve.m, then sweeps all 128
%   within-UI phases and evaluates the LIVE decision-directed classic MM
%   timing error under two transition-filtering schemes:
%     Scheme B (symmetric transitions): keep pairs with d[n] == -d[n-1],
%       i.e. -3<->+3 and -1<->+1.
%     Scheme A (outer transitions only): keep pairs -3<->+3.
%   The unfiltered live curve and the data-aided reference are overlaid for
%   comparison. Transition filtering drops the small-swing / ISI-corrupted
%   pairs that create the shallow false-lock wells, aiming to leave a single
%   stable zero at the eye center (index 78). The closed loop is untouched;
%   this is a diagnostic S-curve sweep only. Saves a text dump and a PNG.

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(fileparts(fileparts(validationDir))));
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

waveformCsv = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', 'ctle_out.csv');
resultDir = fullfile(validationDir, 'results', 'mmpd_Scurve_v2_cdr_transition_filtering');
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

% --- Sweep all 128 phases, compute every detector variant ----------------
phaseList = 0:(samplesPerUI - 1);
liveScurve = zeros(1, numel(phaseList));
liveScurveSymmetric = zeros(1, numel(phaseList));
liveScurveOuter = zeros(1, numel(phaseList));
daScurve = zeros(1, numel(phaseList));
countSymmetric = zeros(1, numel(phaseList));
countOuter = zeros(1, numel(phaseList));
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

    sampled = reshape(codeToSymbol(ffeValidPhi), 1, []);

    % Data-aided error (fixed eye-center decisions).
    slicerErrorDa = sampled - referenceSymbol;
    timingDa = referenceSymbol(1:end - 1) .* slicerErrorDa(2:end) - ...
        referenceSymbol(2:end) .* slicerErrorDa(1:end - 1);
    daScurve(phaseIdx) = mean(timingDa);

    % Live decision-directed error (decisions re-made at this phase).
    [~, decisionIndex] = min(abs(sampled(:) - symbolLevels), [], 2);
    decision = reshape(symbolLevels(decisionIndex), 1, []);
    slicerErrorLive = sampled - decision;
    timingPair = decision(1:end - 1) .* slicerErrorLive(2:end) - ...
        decision(2:end) .* slicerErrorLive(1:end - 1);
    liveScurve(phaseIdx) = mean(timingPair);

    % Transition filtering on the LIVE decisions.
    decisionPrev = decision(1:end - 1);
    decisionCur = decision(2:end);
    maskSymmetric = (decisionCur == -decisionPrev);              % scheme B: -3<->+3 and -1<->+1
    maskOuter = maskSymmetric & (abs(decisionPrev) == 3);        % scheme A: -3<->+3 only
    countSymmetric(phaseIdx) = sum(maskSymmetric);
    countOuter(phaseIdx) = sum(maskOuter);
    liveScurveSymmetric(phaseIdx) = safeMean(timingPair(maskSymmetric));
    liveScurveOuter(phaseIdx) = safeMean(timingPair(maskOuter));
end

% --- Zero crossings of each live curve on the phase-index axis -----------
fprintf('Unfiltered live S-curve:\n');
liveZeros = reportZeros(phaseList, liveScurve, samplesPerUI);
fprintf('Scheme B (symmetric -3<->+3 and -1<->+1):\n');
liveZerosSymmetric = reportZeros(phaseList, liveScurveSymmetric, samplesPerUI);
fprintf('Scheme A (outer -3<->+3 only):\n');
liveZerosOuter = reportZeros(phaseList, liveScurveOuter, samplesPerUI);

% --- Save dump and plot --------------------------------------------------
dumpPath = fullfile(resultDir, 'mmpd_cdr_transition_filtering.txt');
fid = fopen(dumpPath, 'w');
fprintf(fid, ' idx      live     schemeB     schemeA  data-aided    nB    nA\n');
for k = 1:samplesPerUI
    fprintf(fid, '%4d  %+9.4f  %+9.4f  %+9.4f  %+9.4f  %4d  %4d\n', ...
        phaseList(k), liveScurve(k), liveScurveSymmetric(k), ...
        liveScurveOuter(k), daScurve(k), countSymmetric(k), countOuter(k));
end
fclose(fid);

figLive = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 500]);
plot(phaseList, liveScurve, '-o', 'MarkerSize', 3, 'LineWidth', 1.0, ...
    'Color', [0.85 0.33 0.10]);
hold on;
plot(phaseList, liveScurveSymmetric, '-s', 'MarkerSize', 3, 'LineWidth', 1.5, ...
    'Color', [0.20 0.65 0.30]);
plot(phaseList, liveScurveOuter, '-^', 'MarkerSize', 3, 'LineWidth', 1.3, ...
    'Color', [0.55 0.20 0.65]);
plot(phaseList, daScurve, '-', 'LineWidth', 1.3, 'Color', [0.20 0.45 0.75]);
yline(0, 'k-', 'LineWidth', 0.5);
xline(dataPhase, 'k:', 'LineWidth', 0.8);
grid on;
xlabel('Sampling phase index (0..127)');
ylabel('Mean MM timing error');
legend({'live (unfiltered)', 'scheme B: symmetric', 'scheme A: outer only', ...
    'data-aided reference'}, 'Location', 'best');
title('Transition-filtered live MM S-curve (eye center index 78)');
xlim([0 127]);
plotPath = fullfile(resultDir, 'mmpd_cdr_transition_filtering.png');
exportgraphics(figLive, plotPath, 'Resolution', 200);
close(figLive);

fprintf('Unfiltered live zeros (index): %s\n', mat2str(round(liveZeros * 100) / 100));
fprintf('Scheme B live zeros (index)  : %s\n', mat2str(round(liveZerosSymmetric * 100) / 100));
fprintf('Scheme A live zeros (index)  : %s\n', mat2str(round(liveZerosOuter * 100) / 100));
fprintf('Saved dump : %s\n', dumpPath);
fprintf('Saved plot : %s\n', plotPath);

result = struct();
result.PhaseList = phaseList;
result.LiveScurve = liveScurve;
result.LiveScurveSymmetric = liveScurveSymmetric;
result.LiveScurveOuter = liveScurveOuter;
result.DataAidedScurve = daScurve;
result.LiveZeros = liveZeros;
result.LiveZerosSymmetric = liveZerosSymmetric;
result.LiveZerosOuter = liveZerosOuter;
result.TransitionCountSymmetric = countSymmetric;
result.TransitionCountOuter = countOuter;
result.DumpPath = dumpPath;
result.PlotPath = plotPath;
end

function crossings = reportZeros(phaseList, curve, samplesPerUI)
%REPORTZEROS Locate and print zero crossings of a wrapped S-curve.
crossings = [];
for k = 1:samplesPerUI
    kNext = mod(k, samplesPerUI) + 1;
    y1 = curve(k);
    y2 = curve(kNext);
    if isnan(y1) || isnan(y2)
        continue;
    end
    if y1 == 0
        crossings(end + 1) = phaseList(k); %#ok<AGROW>
    elseif y1 * y2 < 0
        slope = y2 - y1;
        stable = slope < 0;   % negative slope with errorSign=+1 => stable
        cross = phaseList(k) - y1 / slope;
        crossings(end + 1) = cross; %#ok<AGROW>
        fprintf('  zero near index %6.2f  slope %+8.4f  %s\n', ...
            cross, slope, ternary(stable, 'STABLE', 'unstable'));
    end
end
end

function m = safeMean(values)
%SAFEMEAN Mean that returns NaN for an empty selection.
if isempty(values)
    m = NaN;
else
    m = mean(values);
end
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
