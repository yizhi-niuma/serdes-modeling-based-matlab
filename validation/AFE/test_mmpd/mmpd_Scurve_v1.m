function result = mmpd_Scurve_v1
%MMPD_SCURVE_V1 Block-processed TI ADC + 6-tap CDR FFE and classic MMPD S-curve.
%   The CTLE output waveform is sampled by a 64-lane 7-bit time-interleaved
%   ADC that is fed one 64-UI block at a time, always at data phase index
%   78 (the maximum-eye-opening phase found earlier). A symbol-spaced 6-tap
%   CDR FFE (2 pre + 1 main + 3 post) is then designed so the combined
%   signal-path unit-UI response keeps main = 1, forces pre1 = post1 and
%   drives every other ISI cursor to approximately zero. Finally a classic
%   PAM4 Mueller-Muller phase detector (MMPD) is driven from the sampled
%   data: the code thresholds and level centers estimated at index 78 give a
%   hard PAM4 decided level d and a slicer error e = y - d (both real-valued,
%   no sign quantization), and the sampling phase is swept from 0 to 127 UI
%   to trace the classic MMPD S-curve tau[n] = d[n-1]*e[n] - d[n]*e[n-1]
%   (mean timing error versus phase). The script plots the
%   ADC code histogram at index = 78, the CDR FFE output histogram and the
%   MMPD S-curve.

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(fileparts(validationDir)));
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

waveformCsv = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', 'ctle_out.csv');
resultDir = fullfile(validationDir, 'results');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

% --- Configuration -------------------------------------------------------
samplesPerUI = 128;
symbolRate = 56e9;
blockSize = 64;
startUi = 20;            % skip the leading settling / invalid delay
numBits = 7;
adcLow = -0.3;
adcHigh = 0.3;
sarPerTah = 8;
inputMargin = samplesPerUI;
dataPhase = 78;          % maximum-eye-opening phase (0-based within one UI)
preTapCount = 2;         % 2 precursor taps
postTapCount = 3;        % 3 postcursor taps

% --- Load the CTLE output waveform --------------------------------------
fixture = readmatrix(waveformCsv);
fixture = fixture(all(isfinite(fixture), 2), :);
assert(size(fixture, 2) >= 2, 'CTLE fixture must contain time and voltage.');
time = fixture(:, 1).';
voltage = fixture(:, end).';
sampleInterval = median(diff(time));
expectedInterval = 1 / (symbolRate * samplesPerUI);
assert(abs(sampleInterval / expectedInterval - 1) < 1e-3, ...
    'CTLE fixture sample interval is inconsistent with 128 samples/UI.');
overdriveFraction = mean(voltage < adcLow | voltage > adcHigh);
waveformMin = min(voltage);
waveformMax = max(voltage);
waveformP001 = prctile(voltage, 0.1);
waveformP999 = prctile(voltage, 99.9);

% --- Instantiate the block-processing TI ADC ----------------------------
adc = ti_adc_top(blockSize, adcLow, adcHigh, numBits, sarPerTah, samplesPerUI);
adc.setInputMargin(inputMargin);
adc.resetState();

% Physical-lane -> time-order mapping for one 64-UI block.
physicalLane = 1:blockSize;
phaseIndexLane = floor((physicalLane - 1) / sarPerTah) + 1;
sarIndexInPhase = mod(physicalLane - 1, sarPerTah) + 1;
timeOrderIndex = (sarIndexInPhase - 1) * (blockSize / sarPerTah) + phaseIndexLane;

% Determine how many 64-UI blocks fit inside the usable waveform.
nominalLength = (blockSize - 1) * samplesPerUI + 1;
maxFirstUi = floor((numel(voltage) - nominalLength - inputMargin - 1) / samplesPerUI);
numBlocks = floor((maxFirstUi - startUi) / blockSize) + 1;
assert(numBlocks >= 1, 'CTLE fixture is too short for one ADC block.');

% --- Block-by-block ADC conversion at the fixed data phase --------------
codeMatrix = zeros(numBlocks, blockSize);
for blockIndex = 1:numBlocks
    firstUi = startUi + (blockIndex - 1) * blockSize;
    nominalStart = firstUi * samplesPerUI + 1;
    localStart = nominalStart - inputMargin;
    localStop = nominalStart + nominalLength - 1 + inputMargin;
    assert(localStart >= 1 && localStop <= numel(voltage), ...
        'CTLE fixture does not contain the required local ADC block margin.');
    localWaveform = voltage(localStart:localStop);

    physicalCode = adc.convertOneBlockFast(localWaveform, dataPhase + 1);
    codeBlock = zeros(1, blockSize);
    codeBlock(timeOrderIndex) = physicalCode;
    codeMatrix(blockIndex, :) = codeBlock;
end

% Time-ordered per-UI ADC code stream sampled at index = dataPhase.
codeStream = reshape(codeMatrix.', 1, []);
assert(all(codeStream >= 0 & codeStream <= 2^numBits - 1), ...
    'TI ADC produced an out-of-range digital code.');

% --- Estimate the symbol-spaced unit-UI (pulse) response ----------------
% PAM4 code centers and hard symbols come from the eye-center code stream.
codeCenter = estimatePam4Centers(double(codeStream));
codeThreshold = (codeCenter(1:3) + codeCenter(2:4)) / 2;
symbolLevel = double(codeStream > codeThreshold(1)) + ...
    double(codeStream > codeThreshold(2)) + ...
    double(codeStream > codeThreshold(3));           % 0..3
symbol = 2 * symbolLevel - 3;                        % {-3,-1,1,3}, zero-mean

received = double(codeStream) - mean(double(codeStream));
symbolPower = mean(symbol .^ 2);

% Cross-correlation gives the symbol-spaced channel pulse response because
% the PAM4 symbols are (approximately) white: p[k] = E{r[n] s[n-k]} / E{s^2}.
lagRange = -(preTapCount + 3):(postTapCount + 3);
pulse = zeros(1, numel(lagRange));
for lagIndex = 1:numel(lagRange)
    lag = lagRange(lagIndex);
    n = max(1, 1 + lag):min(numel(received), numel(received) + lag);
    pulse(lagIndex) = mean(received(n) .* symbol(n - lag)) / symbolPower;
end
[~, mainLagIndex] = max(abs(pulse));
pulse = pulse / pulse(mainLagIndex);                 % normalize main cursor to 1
mainLag = lagRange(mainLagIndex);

% --- Solve the constrained 6-tap FFE ------------------------------------
% Combined response d[m] = sum_tau c[tau] * p[m - tau], with FFE taps at
% delays tau in {-2,-1,0,1,2,3} and the main coefficient c(0) fixed to 1.
% Target: d(main)=1, d(pre1)=d(post1)=a (free, symmetric), all other ISI 0.
tapDelays = (-preTapCount):postTapCount;             % [-2 -1 0 1 2 3]
freeDelays = tapDelays(tapDelays ~= 0);              % 5 free taps
% Combined-response index window (relative to the main cursor).
mRange = tapDelays;   % zero-force only the cursors the FFE can control
pAt = @(k) getPulse(pulse, lagRange, mainLag, k);    % pulse sample at cursor k

A = zeros(numel(mRange), numel(freeDelays) + 1);     % unknowns: 5 taps + a
b = zeros(numel(mRange), 1);
for row = 1:numel(mRange)
    m = mRange(row);
    for col = 1:numel(freeDelays)
        A(row, col) = pAt(m - freeDelays(col));
    end
    if m == -1 || m == 1
        A(row, end) = -1;                            % target value a
    end
    b(row) = -pAt(m);                                % move fixed main tap term
    if m == 0
        b(row) = b(row) + 1;                         % target main = 1
    end
end
solution = A \ b;
freeTaps = solution(1:numel(freeDelays)).';
residualCursor = solution(end);

coefficients = zeros(1, numel(tapDelays));
coefficients(tapDelays == 0) = 1;                    % fixed main tap
coefficients(tapDelays ~= 0) = freeTaps;

combined = conv(coefficients, pulse);
combinedLag = (tapDelays(1) + lagRange(1)) : (tapDelays(end) + lagRange(end));
combinedLag = combinedLag - mainLag;                 % re-center on main cursor

% --- Run the code stream through the CDR FFE ----------------------------
ffe = cdr_ffe(coefficients, preTapCount);
[ffeOutput, ~, validOutput] = ffe.processBlock(codeStream);
ffeValid = ffeOutput(validOutput);

% --- Classic PAM4 MMPD S-curve ------------------------------------------
% The thresholds/level centers estimated at index 78 give the data slicer and
% the decided-level amplitudes. The classic (baud-rate) Mueller-Muller phase
% detector forms the timing error from the *sample amplitudes*,
%   e[k] = ahat[k-1] * y[k] - ahat[k] * y[k-1],
% where ahat is the decided level amplitude and y is the zero-mean sample.
% Sweeping the sampling phase over one UI and averaging e[k] traces the
% classic S-curve; it crosses zero at the phase the MMPD would lock to.
sweepUi = numBlocks * blockSize;                     % UI used per phase sample
[mmpdMeanDecision, mmpdValidCount] = measureClassicMmpdCharacteristic( ...
    voltage, adcLow, adcHigh, numBits, codeThreshold, codeCenter, ...
    samplesPerUI, startUi, sweepUi);
phaseAxis = 0:samplesPerUI - 1;
[~, zeroCrossIndex] = min(abs(mmpdMeanDecision));
mmpdLockPhase = phaseAxis(zeroCrossIndex);

% --- Plot the ADC / FFE histograms --------------------------------------
figurePath = fullfile(resultDir, 'mmpd_scurve_histograms.png');
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1200 500]);
tiled = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tiled, sprintf('CTLE -> block TI ADC (phase %d) -> 6-tap CDR FFE', dataPhase));

nexttile;
codeEdges = -0.5:(2^numBits - 0.5);
histogram(codeStream, codeEdges, 'FaceColor', [0.20 0.45 0.75], 'EdgeColor', 'none');
hold on;
yl = ylim;
for levelIndex = 1:4
    xline(codeCenter(levelIndex), 'r--', 'LineWidth', 1.0);
end
ylim(yl);
grid on;
xlabel('ADC code');
ylabel('count');
xlim([min(codeStream) - 2, max(codeStream) + 2]);
title(sprintf('ADC code histogram at index = %d (%d UI)', dataPhase, numel(codeStream)));

nexttile;
histogram(ffeValid, 60, 'FaceColor', [0.85 0.40 0.20], 'EdgeColor', 'none');
grid on;
xlabel('CDR FFE output (code domain)');
ylabel('count');
title(sprintf('CDR FFE output histogram (%d valid UI)', numel(ffeValid)));

exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);

% --- Plot the classic MMPD S-curve --------------------------------------
scurvePath = fullfile(resultDir, 'mmpd_scurve.png');
figScurve = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 900 520]);
plot(phaseAxis, mmpdMeanDecision, 'b-', 'LineWidth', 1.4);
hold on;
yline(0, 'k--');
xline(dataPhase, 'r:', 'LineWidth', 1.2);
xline(mmpdLockPhase, 'm--', 'LineWidth', 1.2);
grid on;
xlim([0 samplesPerUI - 1]);
xlabel('sampling phase within one UI (0..127)');
ylabel('mean MMPD timing error (code^2 domain)');
title(sprintf(['Classic PAM4 MMPD S-curve (data phase %d, lock phase %d, ' ...
    '%d UI/phase)'], dataPhase, mmpdLockPhase, sweepUi));
legend('MMPD S-curve', 'zero', 'data phase (index 78)', ...
    'MMPD zero crossing', 'Location', 'best');
exportgraphics(figScurve, scurvePath, 'Resolution', 200);
close(figScurve);

% --- Diagnostics and result --------------------------------------------
fprintf('Usable blocks: %d (%d UI), start UI = %d, data phase = %d.\n', ...
    numBlocks, numel(codeStream), startUi, dataPhase);
fprintf('ADC input overdrive fraction: %.6g.\n', overdriveFraction);
fprintf(['Waveform range: min = %.4f V, max = %.4f V, [0.1%%, 99.9%%] = ' ...
    '[%.4f, %.4f] V (ADC full scale = [%.2f, %.2f] V).\n'], ...
    waveformMin, waveformMax, waveformP001, waveformP999, adcLow, adcHigh);
fprintf('PAM4 code centers: %s.\n', mat2str(codeCenter, 5));
fprintf('PAM4 code thresholds: %s.\n', mat2str(codeThreshold, 5));
fprintf('Estimated main-cursor lag: %d UI.\n', mainLag);
fprintf('FFE coefficients (pre..post): %s.\n', mat2str(coefficients, 4));
fprintf('Combined pre1 = %.4f, post1 = %.4f, main = %.4f.\n', ...
    combinedValue(combined, combinedLag, -1), ...
    combinedValue(combined, combinedLag, 1), ...
    combinedValue(combined, combinedLag, 0));
fprintf('Residual symmetric cursor a = %.4f.\n', residualCursor);
fprintf('MMPD S-curve zero crossing phase: %d UI (data phase = %d).\n', ...
    mmpdLockPhase, dataPhase);
fprintf('MMPD symbol pairs at data phase: %d.\n', mmpdValidCount(dataPhase + 1));
fprintf('Saved histogram PNG: %s\n', figurePath);
fprintf('Saved S-curve PNG: %s\n', scurvePath);

result = struct();
result.WaveformCsv = waveformCsv;
result.DataPhase = dataPhase;
result.StartUi = startUi;
result.NumBlocks = numBlocks;
result.CodeStream = codeStream;
result.CodeCenter = codeCenter;
result.CodeThreshold = codeThreshold;
result.PulseResponse = pulse;
result.PulseLag = lagRange - mainLag;
result.MainLag = mainLag;
result.FfeCoefficients = coefficients;
result.CombinedResponse = combined;
result.CombinedLag = combinedLag;
result.ResidualCursor = residualCursor;
result.FfeOutput = ffeOutput;
result.FfeValidOutput = ffeValid;
result.MmpdPhase = phaseAxis;
result.MmpdMeanDecision = mmpdMeanDecision;
result.MmpdValidCount = mmpdValidCount;
result.MmpdLockPhase = mmpdLockPhase;
result.OverdriveFraction = overdriveFraction;
result.FigurePath = figurePath;
result.ScurvePath = scurvePath;
end

function [meanError, sampleCount] = measureClassicMmpdCharacteristic( ...
        voltage, adcLow, adcHigh, numBits, threshold, center, ...
        samplesPerUI, startUi, numUi)
%MEASURECLASSICMMPDCHARACTERISTIC Classic PAM4 MMPD S-curve over one UI sweep.
%   For each sampling phase the whole UI window is quantized by an ideal SAR
%   core and sliced into PAM4 data symbols. The classic (baud-rate)
%   Mueller-Muller timing error uses the decided data level d and the slicer
%   error signal e = y - d directly (no sign quantization),
%       tau[n] = d[n-1] * e[n] - d[n] * e[n-1],
%   where d is the zero-mean decided level amplitude and y is the zero-mean
%   sample. The mean timing error over all symbol pairs is returned per phase.
adc = sar_adc_core(adcLow, adcHigh, numBits);
levelReference = mean(center);           % common DC reference for y and d
meanError = zeros(1, samplesPerUI);
sampleCount = zeros(1, samplesPerUI);
uiIndex = startUi + (0:numUi - 1);
for phase = 0:samplesPerUI - 1
    index = uiIndex * samplesPerUI + phase + 1;
    previousIndex = (startUi - 1) * samplesPerUI + phase + 1;
    code = double(adc.convertVectorFast(voltage(index)));
    previousCode = double(adc.convertInstantFast(voltage(previousIndex)));

    % Decided data level d[k] (zero-mean) and slicer error e[k] = y[k] - d[k].
    decidedData = decidedLevel(code, threshold, center) - levelReference;
    errorSignal = (code - levelReference) - decidedData;
    previousDecidedData = decidedLevel(previousCode, threshold, center) - levelReference;
    previousErrorSignal = (previousCode - levelReference) - previousDecidedData;

    dataPrev = [previousDecidedData decidedData(1:end - 1)];
    errorPrev = [previousErrorSignal errorSignal(1:end - 1)];

    % Classic Mueller-Muller PAM4 timing error, averaged over the block:
    %   tau[n] = d[n-1] * e[n] - d[n] * e[n-1].
    timingError = dataPrev .* errorSignal - decidedData .* errorPrev;
    sampleCount(phase + 1) = numel(timingError);
    meanError(phase + 1) = mean(timingError);
end
end

function amplitude = decidedLevel(code, threshold, center)
%DECIDEDLEVEL Slice ADC codes into PAM4 symbols and return the decided level.
%   The hard PAM4 symbol (0..3) is obtained from the three code thresholds and
%   mapped to its estimated code-domain level center.
code = double(code);
symbol = double(code > threshold(1)) + double(code > threshold(2)) + ...
    double(code > threshold(3));
amplitude = center(symbol + 1);
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

function value = combinedValue(combined, combinedLag, cursor)
%COMBINEDVALUE Return the combined-response sample at a given cursor offset.
idx = find(combinedLag == cursor, 1);
if isempty(idx)
    value = 0;
else
    value = combined(idx);
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
