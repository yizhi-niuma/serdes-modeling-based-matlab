function result = mmpd_Scurve_v2_cdr_schemeB
%MMPD_SCURVE_V2_CDR_SCHEMEB Closed-loop CDR with scheme-B transition filtering.
%   Identical to mmpd_Scurve_v2_cdr.m in every respect (TI ADC + zero-forcing
%   CDR FFE signal path, classic Mueller-Muller detector, cdr_loop PI filter,
%   cdr_pi phase interpolator, tuned Kp / Ki, 16 initial phases) EXCEPT that
%   the block-mean classic MM timing error fed to the loop now keeps only
%   symmetric transitions d[n] == -d[n-1] (scheme B: -3<->+3 and -1<->+1).
%   The unfiltered live S-curve has three stable zeros (index ~4, ~32, 78) so
%   only 9/16 phases lock; the transition-filtered diagnostic showed scheme B
%   removes the ~4 and ~32 false wells, leaving the eye-center zero (index 78)
%   plus a weak zero near the UI edge. This script tests whether that carries
%   over to the real closed loop and yields full-phase acquisition. All
%   trajectories, the reference S-curve, a text report and a result MAT file
%   are stored under results/mmpd_Scurve_v2_cdr_schemeB.

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(fileparts(fileparts(validationDir))));
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

waveformCsv = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', 'ctle_out.csv');
resultDir = fullfile(validationDir, 'results', 'mmpd_Scurve_v2_cdr_schemeB');
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

% --- CDR closed-loop configuration --------------------------------------
% The PI code width matches samplesPerUI so one code equals one sample index.
% Kp / Ki are the loop-filter gains tuned for full-phase acquisition. errorSign
% aligns the MM detector polarity with the phase-interpolator direction so the
% feedback is negative around the eye-center zero crossing.
numBitPi = 7;                        % NumCode = 2^7 = 128 = samplesPerUI
Kp = 0.6;                            % proportional gain (code / phaseError)
Ki = 0.02;                           % integral gain (code / block / phaseError)
maxDeltaCode = 1;                    % hardware-style 1 code/block slew limit
errorSign = 1;                       % MM error polarity into the loop filter
initialPhaseList = 0:8:(samplesPerUI - 1);   % 16 initial phases over one UI
maxIterations = 800;                 % processed blocks per initial phase
lockTolerance = 2;                   % samples; |index - dataPhase| within = in lock
lockHold = 20;                       % consecutive in-tolerance blocks to declare lock

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
% The per-block local waveforms are cached so both the closed loop and the
% reference S-curve sweep can resample the exact same blocks at any phase.
localBlockMatrix = zeros(numBlocks, nominalLength + 2 * inputMargin);
codeMatrix = zeros(numBlocks, blockSize);
for blockIndex = 1:numBlocks
    firstUi = startUi + (blockIndex - 1) * blockSize;
    nominalStart = firstUi * samplesPerUI + 1;
    localStart = nominalStart - inputMargin;
    localStop = nominalStart + nominalLength - 1 + inputMargin;
    assert(localStart >= 1 && localStop <= numel(voltage), ...
        'CTLE fixture does not contain the required local ADC block margin.');
    localWaveform = voltage(localStart:localStop);
    localBlockMatrix(blockIndex, :) = localWaveform;

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
symbolLevelStream = double(codeStream > codeThreshold(1)) + ...
    double(codeStream > codeThreshold(2)) + ...
    double(codeStream > codeThreshold(3));           % 0..3
symbol = 2 * symbolLevelStream - 3;                  % {-3,-1,1,3}, zero-mean

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
% Same zero-forcing design as mmpd_Scurve_v2.m: main tap held at 1, pre1 and
% post1 forced to targetCursor, every other in-window cursor forced to 0.
targetCursor = 0.1;                                  % required pre1 = post1
tapDelays = (-preTapCount):postTapCount;             % full tap-delay grid
freeDelays = tapDelays(tapDelays ~= 0);              % free taps (main fixed)
pAt = @(k) getPulse(pulse, lagRange, mainLag, k);    % pulse sample at cursor k

controlCursors = freeDelays;
targetResponse = zeros(numel(controlCursors), 1);
targetResponse(controlCursors == -1) = targetCursor; % pre1
targetResponse(controlCursors == 1) = targetCursor;  % post1

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

unitUiCursors = tapDelays;                           % [-preTapCount .. postTapCount]
unitUiResponse = arrayfun(@(m) combinedValue(combined, combinedLag, m), unitUiCursors);

% --- Calibrate the code-domain FFE output to the PAM4 symbol domain ------
% The eye-center FFE output calibrates the linear code->symbol map that the
% live slicer uses inside the loop. Calibration is done once at the eye center
% and reused at every phase, exactly like the reference S-curve.
ffe = cdr_ffe(coefficients, preTapCount);
[ffeOutput, ~, validOutput] = ffe.processBlock(codeStream);
ffeValid = ffeOutput(validOutput);

symbolLevels = [-3 -1 1 3];
ffeCenter = estimatePam4Centers(ffeValid);
symbolMap = polyfit(ffeCenter, symbolLevels, 1);     % code-domain FFE -> symbol
codeToSymbol = @(x) symbolMap(1) * x + symbolMap(2);

% --- Reference classic Mueller-Muller S-curve over one full UI ----------
% Recomputed here purely as a reference overlay for the trajectory plot; the
% detector itself is identical to mmpd_Scurve_v2.m.
referenceLevel = codeToSymbol(ffeValid);
[~, referenceIndex] = min(abs(referenceLevel(:) - symbolLevels), [], 2);
referenceSymbol = symbolLevels(referenceIndex);
referenceSymbol = reshape(referenceSymbol, 1, []);

phaseList = 0:(samplesPerUI - 1);
scurve = zeros(1, numel(phaseList));
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

    sampledLevel = codeToSymbol(ffeValidPhi);
    slicerError = sampledLevel - referenceSymbol;
    timingError = referenceSymbol(1:end - 1) .* slicerError(2:end) - ...
        referenceSymbol(2:end) .* slicerError(1:end - 1);
    scurve(phaseIdx) = mean(timingError);
end

phaseOffsetSamples = mod(phaseList - dataPhase + samplesPerUI / 2, samplesPerUI) - samplesPerUI / 2;
phaseOffsetUi = phaseOffsetSamples / samplesPerUI;
[phaseOffsetUiSorted, sortIndex] = sort(phaseOffsetUi);
scurveSorted = scurve(sortIndex);

signChange = scurveSorted(1:end - 1) .* scurveSorted(2:end) <= 0;
crossIndices = find(signChange);
if isempty(crossIndices)
    [~, nearestIndex] = min(abs(scurveSorted));
    lockOffsetUi = phaseOffsetUiSorted(nearestIndex);
    detectorGain = NaN;
else
    crossMidpoints = (phaseOffsetUiSorted(crossIndices) + phaseOffsetUiSorted(crossIndices + 1)) / 2;
    [~, whichCross] = min(abs(crossMidpoints));
    idx = crossIndices(whichCross);
    x1 = phaseOffsetUiSorted(idx);
    x2 = phaseOffsetUiSorted(idx + 1);
    y1 = scurveSorted(idx);
    y2 = scurveSorted(idx + 1);
    if y2 == y1
        lockOffsetUi = x1;
        detectorGain = 0;
    else
        lockOffsetUi = x1 - y1 * (x2 - x1) / (y2 - y1);
        detectorGain = (y2 - y1) / (x2 - x1);
    end
end

% --- CDR real-time closed-loop simulation -------------------------------
% Manual loop: classic MM detector -> cdr_loop (PI) -> cdr_pi (phase). The PI
% ideal table makes one code equal one within-UI sample index, so the phase
% fed to the ADC is simply the wrapped PI code. The FFE keeps its stream
% history across blocks, matching a real per-block hardware pipeline. The MM
% error uses scheme-B transition filtering (symmetric d[n] == -d[n-1] pairs).
piModel = cdr_pi(numBitPi, samplesPerUI);
piModel.resetNonideal();             % ideal linear table: PI code == sample index
loopModel = cdr_loop(Kp, Ki, -Inf, Inf, maxDeltaCode);

numInitialPhase = numel(initialPhaseList);
indexTrajectory = zeros(numInitialPhase, maxIterations);
errorTrajectory = zeros(numInitialPhase, maxIterations);
finalIndex = zeros(1, numInitialPhase);
lockErrorSamples = zeros(1, numInitialPhase);
blocksToLock = zeros(1, numInitialPhase);
lockedFlag = false(1, numInitialPhase);

for phaseIdx = 1:numInitialPhase
    initialPhase = initialPhaseList(phaseIdx);

    ffeLoop = cdr_ffe(coefficients, preTapCount);
    ffeLoop.resetState();
    loopModel.resetState();
    piModel.resetState();
    piModel.setCode(initialPhase);   % start sampling at the chosen phase

    currentPhaseFloat = initialPhase;
    holdCount = 0;
    blocksToLock(phaseIdx) = maxIterations;
    for iteration = 1:maxIterations
        blockIndex = mod(iteration - 1, numBlocks) + 1;
        localWaveform = localBlockMatrix(blockIndex, :);

        currentPhase = mod(round(currentPhaseFloat), samplesPerUI);
        physicalCode = adc.convertOneBlockFast(localWaveform, currentPhase + 1);
        codeBlock = zeros(1, blockSize);
        codeBlock(timeOrderIndex) = physicalCode;

        [ffeBlock, ~, validBlock] = ffeLoop.processBlockFast(codeBlock);
        ffeSamples = ffeBlock(validBlock);

        phaseError = errorSign * classicMmError(ffeSamples, codeToSymbol, symbolLevels);

        deltaCode = loopModel.updateFast(phaseError);
        currentPhaseFloat = piModel.updateFast(deltaCode);

        indexTrajectory(phaseIdx, iteration) = currentPhase;
        errorTrajectory(phaseIdx, iteration) = phaseError;

        offset = mod(currentPhase - dataPhase + samplesPerUI / 2, samplesPerUI) - samplesPerUI / 2;
        if abs(offset) <= lockTolerance
            holdCount = holdCount + 1;
            if holdCount >= lockHold && ~lockedFlag(phaseIdx)
                lockedFlag(phaseIdx) = true;
                blocksToLock(phaseIdx) = iteration - lockHold + 1;
            end
        else
            holdCount = 0;
        end
    end

    finalPhase = mod(round(currentPhaseFloat), samplesPerUI);
    finalIndex(phaseIdx) = finalPhase;
    lockErrorSamples(phaseIdx) = mod(finalPhase - dataPhase + samplesPerUI / 2, ...
        samplesPerUI) - samplesPerUI / 2;
end

allLocked = all(lockedFlag);
maxLockErrorSamples = max(abs(lockErrorSamples));

% --- Plot the CDR sampling-phase acquisition trajectories ---------------
trajPath = fullfile(resultDir, 'mmpd_scurve_cdr_trajectories.png');
figTraj = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 560]);
lineColors = lines(numInitialPhase);
hold on;
for phaseIdx = 1:numInitialPhase
    plot(1:maxIterations, indexTrajectory(phaseIdx, :), '-', ...
        'Color', lineColors(phaseIdx, :), 'LineWidth', 1.0);
end
yline(dataPhase, 'k--', 'LineWidth', 1.2);
grid on;
xlabel('Block iteration');
ylabel('Sampling phase index (0..127)');
ylim([-2, samplesPerUI + 1]);
title(sprintf(['Scheme-B CDR acquisition trajectories  (Kp = %.3g, Ki = %.3g, ' ...
    'maxDelta = %d)  ->  eye center index %d'], Kp, Ki, maxDeltaCode, dataPhase));
text(maxIterations, dataPhase, sprintf('  eye center = %d', dataPhase), ...
    'Color', 'k', 'FontSize', 10, 'VerticalAlignment', 'bottom', ...
    'HorizontalAlignment', 'right');
exportgraphics(figTraj, trajPath, 'Resolution', 200);
close(figTraj);

% --- Plot the MM phase-error trajectories -------------------------------
errPath = fullfile(resultDir, 'mmpd_scurve_cdr_phase_error.png');
figErr = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 500]);
hold on;
for phaseIdx = 1:numInitialPhase
    plot(1:maxIterations, errorTrajectory(phaseIdx, :), '-', ...
        'Color', lineColors(phaseIdx, :), 'LineWidth', 0.9);
end
yline(0, 'k-', 'LineWidth', 0.5);
grid on;
xlabel('Block iteration');
ylabel('Block-mean scheme-B MM timing error');
title('Scheme-B CDR loop phase-error trajectories (converge to 0 at lock)');
exportgraphics(figErr, errPath, 'Resolution', 200);
close(figErr);

% --- Plot the reference classic MMPD S-curve ----------------------------
scurvePath = fullfile(resultDir, 'mmpd_scurve_cdr_scurve.png');
figScurve = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 500]);
plot(phaseOffsetUiSorted, scurveSorted, '-o', 'Color', [0.20 0.45 0.75], ...
    'MarkerSize', 4, 'MarkerFaceColor', [0.20 0.45 0.75], 'LineWidth', 1.4);
hold on;
yline(0, 'k-', 'LineWidth', 0.5);
xline(0, 'k:', 'LineWidth', 0.8);
plot(lockOffsetUi, 0, 'rp', 'MarkerSize', 13, 'MarkerFaceColor', 'r');
grid on;
xlabel(sprintf('Sampling phase offset from eye center (UI)   [eye center = index %d of 0..%d]', ...
    dataPhase, samplesPerUI - 1));
ylabel('Mean MM timing error  E\{e_\tau\}');
title(sprintf(['Reference (data-aided) MMPD S-curve,' ...
    '  lock offset = %+.4f UI'], lockOffsetUi));
xlim([-0.5, 0.5]);
exportgraphics(figScurve, scurvePath, 'Resolution', 200);
close(figScurve);

% --- Save the closed-loop report ----------------------------------------
reportPath = fullfile(resultDir, 'mmpd_scurve_cdr_report.txt');
fid = fopen(reportPath, 'w');
assert(fid > 0, 'Unable to open the CDR report file for writing.');
fprintf(fid, 'CDR closed-loop simulation, scheme-B transition filtering (mmpd_Scurve_v2_cdr_schemeB)\n');
fprintf(fid, '  detector        : classic MMPD e_tau[n] = d[n-1]*e[n] - d[n]*e[n-1]\n');
fprintf(fid, '  filtering       : scheme B, keep symmetric transitions d[n] == -d[n-1]\n');
fprintf(fid, '  loop filter     : cdr_loop (PI), phase interp: cdr_pi (ideal table)\n');
fprintf(fid, '  Kp              : %.6g\n', Kp);
fprintf(fid, '  Ki              : %.6g\n', Ki);
fprintf(fid, '  maxDeltaCode    : %d code/block\n', maxDeltaCode);
fprintf(fid, '  errorSign       : %+d\n', errorSign);
fprintf(fid, '  eye center      : index %d (0..%d)\n', dataPhase, samplesPerUI - 1);
fprintf(fid, '  detector gain   : %.6g per UI at the zero crossing\n', detectorGain);
fprintf(fid, '  blocks / phase  : %d\n', maxIterations);
fprintf(fid, '  lock tolerance  : %d samples, hold %d blocks\n', lockTolerance, lockHold);
fprintf(fid, '\nPer initial-phase acquisition result\n');
fprintf(fid, '  %8s %10s %12s %10s %12s\n', ...
    'init', 'final', 'err(samp)', 'locked', 'blk2lock');
for phaseIdx = 1:numInitialPhase
    fprintf(fid, '  %8d %10d %12d %10d %12d\n', ...
        initialPhaseList(phaseIdx), finalIndex(phaseIdx), ...
        lockErrorSamples(phaseIdx), lockedFlag(phaseIdx), blocksToLock(phaseIdx));
end
fprintf(fid, '\nSummary\n');
fprintf(fid, '  all initial phases locked : %d\n', allLocked);
fprintf(fid, '  max |lock error|          : %d samples\n', maxLockErrorSamples);
fclose(fid);

% --- Diagnostics and result --------------------------------------------
fprintf('Usable blocks: %d (%d UI), start UI = %d, eye-center phase = %d.\n', ...
    numBlocks, numel(codeStream), startUi, dataPhase);
fprintf('Reference S-curve lock offset: %+.6f UI, detector gain: %.6g per UI.\n', ...
    lockOffsetUi, detectorGain);
fprintf('CDR gains: Kp = %.6g, Ki = %.6g, maxDeltaCode = %d, errorSign = %+d (scheme B).\n', ...
    Kp, Ki, maxDeltaCode, errorSign);
fprintf('%8s %10s %12s %8s %10s\n', 'init', 'final', 'err(samp)', 'locked', 'blk2lock');
for phaseIdx = 1:numInitialPhase
    fprintf('%8d %10d %12d %8d %10d\n', ...
        initialPhaseList(phaseIdx), finalIndex(phaseIdx), ...
        lockErrorSamples(phaseIdx), lockedFlag(phaseIdx), blocksToLock(phaseIdx));
end
fprintf('All initial phases locked: %d. Max |lock error|: %d samples.\n', ...
    allLocked, maxLockErrorSamples);
fprintf('Saved trajectory PNG : %s\n', trajPath);
fprintf('Saved phase-error PNG: %s\n', errPath);
fprintf('Saved S-curve PNG    : %s\n', scurvePath);
fprintf('Saved CDR report     : %s\n', reportPath);

result = struct();
result.WaveformCsv = waveformCsv;
result.DataPhase = dataPhase;
result.NumBlocks = numBlocks;
result.Kp = Kp;
result.Ki = Ki;
result.MaxDeltaCode = maxDeltaCode;
result.ErrorSign = errorSign;
result.InitialPhaseList = initialPhaseList;
result.MaxIterations = maxIterations;
result.IndexTrajectory = indexTrajectory;
result.ErrorTrajectory = errorTrajectory;
result.FinalIndex = finalIndex;
result.LockErrorSamples = lockErrorSamples;
result.BlocksToLock = blocksToLock;
result.LockedFlag = lockedFlag;
result.AllLocked = allLocked;
result.MaxLockErrorSamples = maxLockErrorSamples;
result.FfeCoefficients = coefficients;
result.UnitUiCursors = unitUiCursors;
result.UnitUiResponse = unitUiResponse;
result.SymbolMap = symbolMap;
result.PhaseOffsetUi = phaseOffsetUiSorted;
result.Scurve = scurveSorted;
result.LockOffsetUi = lockOffsetUi;
result.DetectorGain = detectorGain;
result.TrajectoryFigurePath = trajPath;
result.PhaseErrorFigurePath = errPath;
result.ScurveFigurePath = scurvePath;
result.ReportPath = reportPath;

resultMatPath = fullfile(resultDir, 'mmpd_scurve_cdr_result.mat');
save(resultMatPath, '-struct', 'result');
fprintf('Saved result MAT     : %s\n', resultMatPath);
end

function phaseError = classicMmError(ffeSamples, codeToSymbol, symbolLevels)
%CLASSICMMERROR Block-mean classic Mueller-Muller timing error, scheme B.
%   Maps the code-domain FFE output to the PAM4 symbol domain, makes live
%   hard decisions and evaluates e_tau[n] = d[n-1]*e[n] - d[n]*e[n-1], then
%   keeps only symmetric transitions d[n] == -d[n-1] (scheme B: -3<->+3 and
%   -1<->+1) before averaging. An empty selection yields zero so the loop
%   simply holds its phase that block.
sampled = reshape(codeToSymbol(ffeSamples), 1, []);
if numel(sampled) < 2
    phaseError = 0;
    return;
end
[~, decisionIndex] = min(abs(sampled(:) - symbolLevels), [], 2);
decision = reshape(symbolLevels(decisionIndex), 1, []);
slicerError = sampled - decision;                    % e[n] = y[n] - d[n]
timingError = decision(1:end - 1) .* slicerError(2:end) - ...
    decision(2:end) .* slicerError(1:end - 1);
maskSymmetric = (decision(2:end) == -decision(1:end - 1));
if any(maskSymmetric)
    phaseError = mean(timingError(maskSymmetric));
else
    phaseError = 0;
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
