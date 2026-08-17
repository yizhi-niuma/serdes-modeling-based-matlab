function result = test_cdr_top_ctle_waveform_mmpd
% test_cdr_top_ctle_waveform_mmpd  Close PAM4 MMPD over the CTLE fixture.
%
% The current cdr_top public block interface is BBPD-specific. This test
% therefore composes cdr_pd.mmpd, cdr_voter, cdr_loop, and cdr_pi directly
% while explicitly carrying previous data/error decisions across blocks.

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(validationDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

waveformCsv = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', 'ctle_out.csv');
resultDir = fullfile(repoRoot, 'results', 'CDR');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

samplesPerUI = 128;
symbolRate = 56e9;
blockSize = 64;
numBlocks = 64;
startUi = 1;

fixture = readmatrix(waveformCsv);
assert(size(fixture, 2) >= 2, 'CTLE fixture must contain time and voltage.');
time = fixture(:, 1);
voltage = fixture(:, 2).';
sampleInterval = median(diff(time));
expectedInterval = 1 / (symbolRate * samplesPerUI);
assert(abs(sampleInterval - expectedInterval) / expectedInterval < 0.02, ...
    'CTLE fixture sample interval does not match 56 GBaud at 128 samples/UI.');
assert(numel(voltage) >= (startUi + blockSize * numBlocks + 1) * samplesPerUI, ...
    'CTLE fixture is too short for the requested MMPD validation.');

% Calibrate four PAM4 centers at the maximum-power data phase, exactly as
% the BBPD fixture test does. MMPD uses the same symbol thresholds but does
% not require a half-UI edge sample.
phasePower = zeros(1, samplesPerUI);
calibrationUi = 0:4095;
for phase = 0:samplesPerUI - 1
    index = calibrationUi * samplesPerUI + phase + 1;
    phasePower(phase + 1) = mean(voltage(index).^2);
end
[~, referenceDataPhaseIndex] = max(phasePower);
referenceDataPhase = referenceDataPhaseIndex - 1;
calibrationIndex = calibrationUi * samplesPerUI + referenceDataPhase + 1;
levelCenter = estimatePam4Centers(voltage(calibrationIndex));
threshold = (levelCenter(1:3) + levelCenter(2:4)) / 2;

% Measure the MMPD S-curve using identical UI and pattern statistics at
% every phase. The selected lock point is the minimum mean valid decision
% within +/-0.25 UI of the maximum-power data phase.
[pdMeanDecision, pdValidCount] = measureMmpdCharacteristic( ...
    voltage, threshold, levelCenter, samplesPerUI, startUi, ...
    blockSize * numBlocks);
phaseCandidate = 0:samplesPerUI - 1;
distanceFromReference = abs(wrapSampleError( ...
    phaseCandidate - referenceDataPhase, samplesPerUI));
lockSearchMask = distanceFromReference <= samplesPerUI / 4 & ...
    pdValidCount >= 0.05 * blockSize * numBlocks;
lockScore = abs(pdMeanDecision);
lockScore(~lockSearchMask) = Inf;
[~, lockIndex] = min(lockScore);
mmpdLockPhase = lockIndex - 1;
assert(isfinite(lockScore(lockIndex)), 'No usable MMPD lock phase was found.');
initialPhase = mod(mmpdLockPhase - 8, samplesPerUI);

% Scan loop gains and both control polarities. Polarity is a wiring choice,
% while Kp/Ki are the requested loop parameters. The score rewards small
% mean lock error, narrow phase span, and low residual drift.
kpCandidate = [0.015625 0.03125 0.0625 0.125 0.25 0.5 1];
kiCandidate = [0 0.000125 0.00025 0.0005 0.001 0.002 0.005];
polarityCandidate = [1 -1];
scan = struct('Kp', {}, 'Ki', {}, 'Polarity', {}, 'Score', {}, ...
    'MeanError', {}, 'PhaseSpan', {}, 'Drift', {}, 'Trace', {});
scanIndex = 0;
for polarity = polarityCandidate
    for kp = kpCandidate
        for ki = kiCandidate
            trace = runClosedLoop(voltage, threshold, levelCenter, ...
                samplesPerUI, startUi, blockSize, numBlocks, ...
                mmpdLockPhase, initialPhase, kp, ki, polarity);
            steady = numBlocks - 15:numBlocks;
            meanError = mean(trace.PhaseErrorSample(steady));
            phaseSpan = max(trace.SampleIndexForBlock(steady)) - ...
                min(trace.SampleIndexForBlock(steady));
            drift = abs(mean(diff(trace.SampleIndexForBlock(steady))));
            scanIndex = scanIndex + 1;
            scan(scanIndex).Kp = kp;
            scan(scanIndex).Ki = ki;
            scan(scanIndex).Polarity = polarity;
            scan(scanIndex).MeanError = meanError;
            scan(scanIndex).PhaseSpan = phaseSpan;
            scan(scanIndex).Drift = drift;
            scan(scanIndex).Score = abs(meanError) + 0.25 * phaseSpan + ...
                8 * drift;
            scan(scanIndex).Trace = trace;
        end
    end
end
feasible = abs([scan.MeanError]) <= 3 & [scan.PhaseSpan] <= 8 & ...
    [scan.Drift] <= 0.25;
if ~any(feasible)
    [~, diagnosticOrder] = sort([scan.Score]);
    for diagnosticIndex = diagnosticOrder(1:min(5, numel(diagnosticOrder)))
        fprintf(['Rejected candidate: Kp=%.6g Ki=%.6g polarity=%+d ' ...
            'mean=%.3f span=%.3f drift=%.3f score=%.3f.\n'], ...
            scan(diagnosticIndex).Kp, scan(diagnosticIndex).Ki, ...
            scan(diagnosticIndex).Polarity, scan(diagnosticIndex).MeanError, ...
            scan(diagnosticIndex).PhaseSpan, scan(diagnosticIndex).Drift, ...
            scan(diagnosticIndex).Score);
    end
end
assert(any(feasible), ...
    'No Kp/Ki candidate met the MMPD steady-state acceptance criteria.');
feasibleScore = [scan.Score];
feasibleScore(~feasible) = Inf;
[~, bestIndex] = min(feasibleScore);
best = scan(bestIndex);
trace = best.Trace;
steady = numBlocks - 15:numBlocks;

fprintf(['MMPD CTLE diagnostic: reference data phase = %d, lock = %d, ' ...
    'initial = %d, Kp = %.6g, Ki = %.6g, polarity = %+d, mean error = %.3f, ' ...
    'span = %.3f, valid = %d.\n'], referenceDataPhase, mmpdLockPhase, ...
    initialPhase, best.Kp, best.Ki, best.Polarity, best.MeanError, best.PhaseSpan, ...
    sum(trace.ValidCount));

assert(sum(trace.ValidCount) >= 0.05 * blockSize * numBlocks, ...
    'Too few symmetric PAM4 transitions were available for MMPD tracking.');
assert(any(trace.PhaseError > 0) && any(trace.PhaseError < 0), ...
    'MMPD voter output did not reverse direction around lock.');
assert(abs(best.MeanError) <= 3, ...
    'Mean steady-state MMPD phase error exceeds three samples.');
assert(best.PhaseSpan <= 8, ...
    'Steady-state MMPD phase span exceeds eight samples.');
assert(best.Drift <= 0.25, ...
    'Steady-state MMPD phase has excessive residual drift.');

figurePath = fullfile(resultDir, 'cdr_top_ctle_convergence_mmpd.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1150 980]);
tiled = tiledlayout(fig, 5, 1, ...
    'TileSpacing', 'compact', 'Padding', 'compact');
title(tiled, 'PAM4 MMPD tracking on CTLE waveform');

nexttile;
plot(0:samplesPerUI - 1, pdMeanDecision, 'b-', 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
xline(referenceDataPhase, 'r:', 'LineWidth', 1.2);
xline(mmpdLockPhase, 'm--', 'LineWidth', 1.2);
grid on;
xlim([0 samplesPerUI - 1]);
ylabel('mean decision');
title('Offline MMPD S-curve');
legend('mean valid decision', 'zero', 'power data phase', ...
    'MMPD lock phase', 'Location', 'best');

blockAxis = 1:numBlocks;
nexttile;
plot(blockAxis, trace.SampleIndexForBlock, 'b-o', ...
    'LineWidth', 1.2, 'MarkerSize', 3);
hold on;
yline(referenceDataPhase, 'r:', 'LineWidth', 1.2);
yline(mmpdLockPhase, 'm--', 'LineWidth', 1.2);
grid on;
ylabel('phase (sample)');
title('Closed-loop PI phase');

nexttile;
stairs(blockAxis, trace.PhaseErrorSample, 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
grid on;
ylabel('error (sample)');
title('Wrapped error relative to MMPD statistical lock');

nexttile;
bar(blockAxis, trace.ValidCount, 0.8, ...
    'FaceColor', [0.2 0.6 0.35], 'EdgeColor', 'none');
grid on;
ylim([0 blockSize]);
ylabel('valid/UI');
title('Valid symmetric transitions per block');

nexttile;
yyaxis left;
stairs(blockAxis, trace.PhaseError, 'LineWidth', 1.2);
ylabel('voter output');
yyaxis right;
stairs(blockAxis, trace.DeltaCode, '--', 'LineWidth', 1.2);
ylabel('\Delta PI code');
grid on;
xlabel('64-UI block index');
title(sprintf('MMPD control: Kp=%.6g, Ki=%.6g, polarity=%+d', ...
    best.Kp, best.Ki, best.Polarity));

exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);

result = struct();
result.WaveformCsv = waveformCsv;
result.SamplesPerUI = samplesPerUI;
result.LevelCenter = levelCenter;
result.Threshold = threshold;
result.ReferenceDataPhase = referenceDataPhase;
result.MmpdLockPhase = mmpdLockPhase;
result.InitialPhase = initialPhase;
result.PdMeanDecision = pdMeanDecision;
result.PdValidCount = pdValidCount;
result.Kp = best.Kp;
result.Ki = best.Ki;
result.Polarity = best.Polarity;
result.Scan = rmfield(scan, 'Trace');
result.Trace = trace;
result.FigurePath = figurePath;

fprintf('test_cdr_top_ctle_waveform_mmpd passed.\n');
fprintf('Saved PNG: %s\n', figurePath);
end

function trace = runClosedLoop(voltage, threshold, levelCenter, ...
        samplesPerUI, startUi, blockSize, numBlocks, lockPhase, initialPhase, Kp, Ki, polarity)
pd = cdr_pd('pam4', polarity);
voter = cdr_voter('constant', blockSize, 8);
loopFilter = cdr_loop(Kp, Ki, -2, 2, 1);
piModel = cdr_pi(8, samplesPerUI);
piModel.resetNonideal();
piModel.setCode(round(initialPhase * piModel.NumCode / samplesPerUI));
currentLocalIndex = piModel.getLocalIndex();

previousIndex = (startUi - 1) * samplesPerUI + samplesPerUI / 2 + 1;
[previousSymbol, previousError] = slicePam4WithError( ...
    voltage(previousIndex), threshold, levelCenter);

sampleIndexForBlock = zeros(1, numBlocks);
phaseError = zeros(1, numBlocks);
deltaCode = zeros(1, numBlocks);
validCount = zeros(1, numBlocks);

for blockIndex = 1:numBlocks
    uiIndex = startUi + (blockIndex - 1) * blockSize + (0:blockSize - 1);
    sampleIndexForBlock(blockIndex) = currentLocalIndex;
    localIndex = round(sampleIndexForBlock(blockIndex));
    dataIndex = uiIndex * samplesPerUI + localIndex + 1;
    [dataCurr, errorCurr] = slicePam4WithError( ...
        voltage(dataIndex), threshold, levelCenter);
    dataPrev = [previousSymbol dataCurr(1:end - 1)];
    errorPrev = [previousError errorCurr(1:end - 1)];
    [decision, valid] = pd.mmpdFast( ...
        dataPrev, errorPrev, dataCurr, errorCurr);
    phaseError(blockIndex) = double(voter.voteFast(decision));
    deltaCode(blockIndex) = loopFilter.updateFast(phaseError(blockIndex));
    currentLocalIndex = piModel.updateFast(deltaCode(blockIndex));
    validCount(blockIndex) = sum(valid);
    previousSymbol = dataCurr(end);
    previousError = errorCurr(end);
end

trace = struct();
trace.SampleIndexForBlock = sampleIndexForBlock;
trace.PhaseErrorSample = wrapSampleError( ...
    sampleIndexForBlock - lockPhase, samplesPerUI);
trace.PhaseError = phaseError;
trace.DeltaCode = deltaCode;
trace.ValidCount = validCount;
end

function [meanDecision, validCount] = measureMmpdCharacteristic( ...
        voltage, threshold, levelCenter, samplesPerUI, startUi, numUi)
pd = cdr_pd('pam4', 1);
meanDecision = zeros(1, samplesPerUI);
validCount = zeros(1, samplesPerUI);
uiIndex = startUi + (0:numUi - 1);
for phase = 0:samplesPerUI - 1
    index = uiIndex * samplesPerUI + phase + 1;
    previousIndex = (startUi - 1) * samplesPerUI + phase + 1;
    [dataCurr, errorCurr] = slicePam4WithError( ...
        voltage(index), threshold, levelCenter);
    [previousSymbol, previousError] = slicePam4WithError( ...
        voltage(previousIndex), threshold, levelCenter);
    dataPrev = [previousSymbol dataCurr(1:end - 1)];
    errorPrev = [previousError errorCurr(1:end - 1)];
    [decision, valid] = pd.mmpdFast( ...
        dataPrev, errorPrev, dataCurr, errorCurr);
    validCount(phase + 1) = sum(valid);
    meanDecision(phase + 1) = sum(double(decision)) / ...
        max(validCount(phase + 1), 1);
end
end

function [symbol, errorBit] = slicePam4WithError(sample, threshold, center)
symbol = double(sample > threshold(1)) + double(sample > threshold(2)) + ...
    double(sample > threshold(3));
symbolCenter = center(symbol + 1);
negativeLevel = symbol <= 1;
errorBit = (negativeLevel & sample > symbolCenter) | ...
    (~negativeLevel & sample < symbolCenter);
end

function levelCenter = estimatePam4Centers(sample)
levelCenter = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    distance = abs(sample(:) - levelCenter);
    [~, clusterIndex] = min(distance, [], 2);
    updatedCenter = levelCenter;
    for levelIndex = 1:4
        levelSample = sample(clusterIndex == levelIndex);
        assert(~isempty(levelSample), 'PAM4 clustering produced an empty level.');
        updatedCenter(levelIndex) = mean(levelSample);
    end
    updatedCenter = sort(updatedCenter);
    if max(abs(updatedCenter - levelCenter)) < 1e-12
        levelCenter = updatedCenter;
        break;
    end
    levelCenter = updatedCenter;
end
end

function errorSample = wrapSampleError(errorSample, samplesPerUI)
errorSample = mod(errorSample + samplesPerUI / 2, samplesPerUI) - ...
    samplesPerUI / 2;
end
