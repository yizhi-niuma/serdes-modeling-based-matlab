function result = mmpd_Scurve_v2
%MMPD_SCURVE_V2 Block-processed TI ADC + zero-forcing CDR FFE at eye center.
%   The CTLE output waveform is sampled by a 64-lane 7-bit time-interleaved
%   ADC that is fed one 64-UI block at a time, always at data phase index
%   78 (the maximum-eye-opening phase found earlier). A symbol-spaced CDR
%   FFE (preTapCount pre + 1 main + postTapCount post) is then designed as a
%   zero-forcing equalizer: every cursor inside the tap span is controlled
%   directly so the combined signal-path unit-UI response keeps main = 1,
%   holds pre1 = post1 = 0.1 and forces every other in-window cursor to 0.
%   Widening the tap span pushes the residual ISI further out and keeps it
%   as small as possible. The script saves the CDR FFE configuration, the
%   final unit-UI response and the CDR FFE output histogram under results.

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(fileparts(fileparts(validationDir))));
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
adcLow = -0.45;
adcHigh = 0.45;
sarPerTah = 8;
inputMargin = samplesPerUI;
dataPhase = 78;          % maximum-eye-opening phase (0-based within one UI)
preTapCount = 6;         % 6 precursor taps (wider null window -> smaller residual ISI)
postTapCount = 10;       % 10 postcursor taps (wider null window -> smaller residual ISI)

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

% --- Solve the zero-forcing FFE -----------------------------------------
% Combined response d[m] = sum_tau c[tau] * p[m - tau]. The main tap is held
% at c(0) = 1 (the CDR FFE normalization) and every other tap is a free
% variable. Each free tap is paired with one controlled cursor so the system
% is square and solved exactly: pre1 = post1 = targetCursor while every other
% in-window cursor (pre2, pre3, pre4, post2, ..., post6) is forced to 0.
% Widening the tap span nulls the near-in ISI exactly and pushes the residual
% further out, keeping every non-(pre1/post1) cursor as small as possible.
targetCursor = 0.1;                                  % required pre1 = post1
tapDelays = (-preTapCount):postTapCount;             % full tap-delay grid
freeDelays = tapDelays(tapDelays ~= 0);              % free taps (main fixed)
pAt = @(k) getPulse(pulse, lagRange, mainLag, k);    % pulse sample at cursor k

% Controlled cursors: every non-main cursor in the tap span (one per free tap).
controlCursors = freeDelays;
targetResponse = zeros(numel(controlCursors), 1);
targetResponse(controlCursors == -1) = targetCursor; % pre1
targetResponse(controlCursors == 1) = targetCursor;  % post1

% d(m) = p(m) [fixed main tap] + sum_freeTau c(freeTau) * p(m - freeTau).
% Move the fixed main-tap term to the right-hand side and solve exactly.
A = zeros(numel(controlCursors), numel(freeDelays));
b = zeros(numel(controlCursors), 1);
for row = 1:numel(controlCursors)
    m = controlCursors(row);
    for col = 1:numel(freeDelays)
        A(row, col) = pAt(m - freeDelays(col));
    end
    b(row) = targetResponse(row) - pAt(m);           % subtract fixed main tap
end
freeTaps = (A \ b).';                                % exact zero-forcing taps

coefficients = zeros(1, numel(tapDelays));
coefficients(tapDelays == 0) = 1;                    % fixed main tap
coefficients(tapDelays ~= 0) = freeTaps;

combined = conv(coefficients, pulse);
combinedLag = (tapDelays(1) + lagRange(1)) : (tapDelays(end) + lagRange(end));
combinedLag = combinedLag - mainLag;                 % re-center on main cursor

% Final combined unit-UI response at every FFE-controllable cursor.
unitUiCursors = tapDelays;                           % [-preTapCount .. postTapCount]
unitUiResponse = arrayfun(@(m) combinedValue(combined, combinedLag, m), unitUiCursors);

% --- Run the code stream through the CDR FFE ----------------------------
ffe = cdr_ffe(coefficients, preTapCount);
[ffeOutput, ~, validOutput] = ffe.processBlock(codeStream);
ffeValid = ffeOutput(validOutput);

% --- Plot the two requested histograms ----------------------------------
figurePath = fullfile(resultDir, 'mmpd_scurve_histograms.png');
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1200 500]);
tiled = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tiled, sprintf('CTLE -> block TI ADC (phase %d) -> %d-tap CDR FFE', ...
    dataPhase, numel(coefficients)));

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

% --- Plot the final combined unit-UI response ---------------------------
responsePath = fullfile(resultDir, 'mmpd_scurve_unit_ui_response.png');
figResp = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 500]);
stem(unitUiCursors, unitUiResponse, 'filled', 'Color', [0.20 0.45 0.75], 'LineWidth', 1.4);
hold on;
yline(0, 'k-', 'LineWidth', 0.5);
yline(targetCursor, 'r--', 'LineWidth', 1.0);
grid on;
xlabel('Cursor (UI)');
ylabel('Combined unit-UI response (main = 1)');
title('CDR FFE output path unit-UI response (pre1 = post1 = 0.1, others = 0)');
xticks(unitUiCursors);
xlim([tapDelays(1) - 0.6, tapDelays(end) + 0.6]);
ylim([-0.15, 1.12]);
for idx = 1:numel(unitUiCursors)
    text(unitUiCursors(idx), unitUiResponse(idx) + 0.035, ...
        sprintf('%+.3f', unitUiResponse(idx)), 'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'bottom', 'FontSize', 9, 'Color', [0.15 0.15 0.15]);
end
exportgraphics(figResp, responsePath, 'Resolution', 200);
close(figResp);

% --- Save the CDR FFE configuration and unit-UI response ----------------
reportPath = fullfile(resultDir, 'mmpd_scurve_ffe_config.txt');
fid = fopen(reportPath, 'w');
assert(fid > 0, 'Unable to open the FFE configuration file for writing.');
fprintf(fid, 'CDR FFE configuration (mmpd_Scurve_v2)\n');
fprintf(fid, '  precursor taps  : %d\n', preTapCount);
fprintf(fid, '  postcursor taps : %d\n', postTapCount);
fprintf(fid, '  total taps      : %d\n', numel(coefficients));
fprintf(fid, '  tap delays (UI) : %s\n', mat2str(tapDelays));
fprintf(fid, '  coefficients    : %s\n', mat2str(coefficients, 6));
fprintf(fid, '  main tap value  : %.6f at delay 0\n', coefficients(tapDelays == 0));
fprintf(fid, '\nTarget unit-UI response\n');
fprintf(fid, '  main = 1, pre1 = post1 = %.4f, every other cursor forced to 0\n', targetCursor);
fprintf(fid, '\nFinal combined unit-UI response (CDR FFE output path)\n');
for idx = 1:numel(unitUiCursors)
    fprintf(fid, '  cursor %+d : %+.6f\n', unitUiCursors(idx), unitUiResponse(idx));
end
fclose(fid);

% --- Diagnostics and result --------------------------------------------
fprintf('Usable blocks: %d (%d UI), start UI = %d, data phase = %d.\n', ...
    numBlocks, numel(codeStream), startUi, dataPhase);
fprintf('ADC input overdrive fraction: %.6g.\n', overdriveFraction);
fprintf('PAM4 code centers: %s.\n', mat2str(codeCenter, 5));
fprintf('Estimated main-cursor lag: %d UI.\n', mainLag);
fprintf('FFE coefficients (pre..post): %s.\n', mat2str(coefficients, 4));
fprintf('Combined pre1 = %.4f, post1 = %.4f, main = %.4f.\n', ...
    combinedValue(combined, combinedLag, -1), ...
    combinedValue(combined, combinedLag, 1), ...
    combinedValue(combined, combinedLag, 0));
fprintf('Combined pre2 = %.4f, post2 = %.4f, post3 = %.4f.\n', ...
    combinedValue(combined, combinedLag, -2), ...
    combinedValue(combined, combinedLag, 2), ...
    combinedValue(combined, combinedLag, 3));
fprintf('Target pre1 = post1 = %.4f (fixed).\n', targetCursor);
fprintf('Saved histogram PNG : %s\n', figurePath);
fprintf('Saved response PNG  : %s\n', responsePath);
fprintf('Saved FFE config    : %s\n', reportPath);

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
result.TargetCursor = targetCursor;
result.UnitUiCursors = unitUiCursors;
result.UnitUiResponse = unitUiResponse;
result.FfeOutput = ffeOutput;
result.FfeValidOutput = ffeValid;
result.OverdriveFraction = overdriveFraction;
result.FigurePath = figurePath;
result.ResponseFigurePath = responsePath;
result.ReportPath = reportPath;

resultMatPath = fullfile(resultDir, 'mmpd_scurve_result.mat');
save(resultMatPath, '-struct', 'result');
fprintf('Saved result MAT    : %s\n', resultMatPath);
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
