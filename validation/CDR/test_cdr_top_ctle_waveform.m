function result = test_cdr_top_ctle_waveform(Kp, Ki)
% test_cdr_top_ctle_waveform  Validate PAM4 CDR tracking on CTLE output.

if nargin < 1
    Kp = 0.0625;
end
if nargin < 2
    Ki = 0.0005;
end

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(validationDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

resultDir = fullfile(repoRoot, 'results', 'CDR');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

waveformCsv = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', ...
    'ctle_out.csv');
waveformData = readmatrix(waveformCsv);
waveformData = waveformData(all(isfinite(waveformData), 2), :);
assert(size(waveformData, 2) >= 2, ...
    'CTLE waveform CSV must contain time and voltage columns.');

time = waveformData(:, 1).';
voltage = waveformData(:, end).';
samplesPerUI = 128;
blockSize = 64;
numBlocks = 64;
startUi = 1;

sampleInterval = median(diff(time));
expectedSampleInterval = 1 / (56e9 * samplesPerUI);
assert(abs(sampleInterval / expectedSampleInterval - 1) < 1e-3, ...
    'CTLE waveform sample interval is inconsistent with 128 samples/UI.');

% Use a data-phase power scan only as an offline reference and threshold
% calibration aid. The CDR itself starts from phase zero.
phasePower = zeros(1, samplesPerUI);
for phaseIndex = 1:samplesPerUI
    phaseSample = voltage(phaseIndex:samplesPerUI:end);
    phasePower(phaseIndex) = mean(phaseSample .^ 2);
end
[~, referenceDataPhaseIndex] = max(phasePower);
referenceDataPhase = referenceDataPhaseIndex - 1;
referenceEdgePhase = mod(referenceDataPhase - samplesPerUI / 2, ...
    samplesPerUI);

calibrationSample = voltage( ...
    referenceDataPhaseIndex:samplesPerUI:end);
levelCenter = estimatePam4Centers(calibrationSample);
threshold = (levelCenter(1:3) + levelCenter(2:4)) / 2;

[pdMeanDecision, pdValidCount] = measurePdCharacteristic( ...
    voltage, threshold, samplesPerUI, startUi, blockSize * numBlocks);
phaseCandidate = 0:samplesPerUI - 1;
distanceFromPowerEdge = abs(wrapSampleError( ...
    phaseCandidate - referenceEdgePhase, samplesPerUI));
lockSearchMask = distanceFromPowerEdge <= samplesPerUI / 4 & ...
    pdValidCount >= 0.05 * blockSize * numBlocks;
lockScore = abs(pdMeanDecision);
lockScore(~lockSearchMask) = Inf;
[~, pdLockPhaseIndex] = min(lockScore);
pdLockPhase = pdLockPhaseIndex - 1;

% Default gains were selected for the fixed CTLE waveform by checking final
% phase error, steady-state phase range, valid-transition density, and drift.

pd = cdr_pd('pam4', 1);
voter = cdr_voter('constant', blockSize, 8);
loopFilter = cdr_loop(Kp, Ki, -2, 2);
piModel = cdr_pi(8, samplesPerUI);
piModel.resetNonideal();

initialDataIndex = (startUi - 1) * samplesPerUI + ...
    samplesPerUI / 2 + 1;
initialSymbol = slicePam4(voltage(initialDataIndex), threshold);
top = cdr_top(pd, voter, loopFilter, piModel, initialSymbol);

sampleIndexForBlock = zeros(1, numBlocks);
nextLocalIndexFloat = zeros(1, numBlocks);
phaseError = zeros(1, numBlocks);
deltaCode = zeros(1, numBlocks);
validCount = zeros(1, numBlocks);
piCode = zeros(1, numBlocks);

for blockIndex = 1:numBlocks
    uiIndex = startUi + (blockIndex - 1) * blockSize + ...
        (0:blockSize - 1);
    localIndexInteger = round(top.CurrentLocalIndexFloat);
    edgeIndex = uiIndex * samplesPerUI + localIndexInteger + 1;
    dataIndex = edgeIndex + samplesPerUI / 2;
    assert(dataIndex(end) <= numel(voltage), ...
        'CTLE waveform does not contain enough samples.');

    dataCurrBlock = slicePam4(voltage(dataIndex), threshold);
    edgeBitBlock = voltage(edgeIndex) > threshold(2);
    output = top.processBlock(dataCurrBlock, edgeBitBlock);

    sampleIndexForBlock(blockIndex) = output.SampleIndexForBlock;
    nextLocalIndexFloat(blockIndex) = output.NextLocalIndexFloat;
    phaseError(blockIndex) = double(output.PhaseError);
    deltaCode(blockIndex) = output.DeltaCode;
    validCount(blockIndex) = sum(output.Valid);
    piCode(blockIndex) = output.PiCodeWrapped;
end

phaseErrorSample = wrapSampleError( ...
    sampleIndexForBlock - pdLockPhase, samplesPerUI);
steadyStateBlock = numBlocks - 15:numBlocks;
steadyStateError = phaseErrorSample(steadyStateBlock);
steadyStatePhase = sampleIndexForBlock(steadyStateBlock);

fprintf(['CTLE CDR diagnostic: power edge = %d, BBPD lock = %d, ' ...
    'final phase = %.3f, ' ...
    'steady mean error = %.3f, range = %.3f to %.3f, valid = %d.\n'], ...
    referenceEdgePhase, pdLockPhase, sampleIndexForBlock(end), ...
    mean(steadyStateError), min(steadyStatePhase), ...
    max(steadyStatePhase), sum(validCount));

assert(sum(validCount) >= 0.1 * blockSize * numBlocks, ...
    'Too few selected PAM4 transitions were available for CDR tracking.');
assert(any(phaseError > 0) && any(phaseError < 0), ...
    'The voter output did not reverse direction around the tracked edge.');
assert(abs(mean(steadyStateError)) <= 3, ...
    'Mean steady-state phase error exceeds three waveform samples.');
assert(max(steadyStatePhase) - min(steadyStatePhase) <= 8, ...
    'Steady-state PI phase range exceeds eight waveform samples.');
assert(abs(mean(diff(steadyStatePhase))) <= 0.25, ...
    'Steady-state PI phase still shows excessive drift.');

figurePath = fullfile(resultDir, 'cdr_top_ctle_convergence.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1150 1200]);
tiled = tiledlayout(fig, 6, 1, ...
    'TileSpacing', 'compact', 'Padding', 'compact');
title(tiled, ['cdr\_top PAM4 tracking on CTLE waveform: ' ...
    '4096 UI, 128 samples/UI']);

nexttile;
plotCtleEye(voltage, samplesPerUI, referenceEdgePhase, threshold);

nexttile;
phaseAxis = 0:samplesPerUI - 1;
plot(phaseAxis, pdMeanDecision, 'b-', 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
xline(referenceEdgePhase, 'r:', 'LineWidth', 1.2);
xline(pdLockPhase, 'm--', 'LineWidth', 1.2);
grid on;
xlim([0 samplesPerUI - 1]);
xlabel('Edge sampling phase (sample)');
ylabel('mean decision');
title('Offline PAM4 BBPD S-curve');
legend('mean valid decision', 'zero', 'power-derived edge', ...
    'selected BBPD lock phase', 'Location', 'best');

blockAxis = 1:numBlocks;
nexttile;
plot(blockAxis, sampleIndexForBlock, ...
    'b-o', 'LineWidth', 1.2, 'MarkerSize', 3);
hold on;
yline(referenceEdgePhase, 'r:', 'LineWidth', 1.2);
yline(pdLockPhase, 'm--', 'LineWidth', 1.2);
grid on;
ylabel('phase (sample)');
title('PI phase versus offline power and BBPD references');
legend('PI phase entering block', 'power-derived edge', ...
    'BBPD statistical lock phase', ...
    'Location', 'best');

nexttile;
stairs(blockAxis, phaseErrorSample, 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
grid on;
ylabel('error (sample)');
title('Wrapped phase error relative to BBPD statistical lock phase');

nexttile;
bar(blockAxis, validCount, 0.8, ...
    'FaceColor', [0.2 0.6 0.35], 'EdgeColor', 'none');
grid on;
ylim([0 blockSize]);
ylabel('valid/UI');
title('Selected PAM4 BBPD transitions per 64-UI block');

nexttile;
yyaxis left;
stairs(blockAxis, phaseError, 'LineWidth', 1.2);
ylabel('voter output');
yyaxis right;
stairs(blockAxis, deltaCode, '--', 'LineWidth', 1.2);
ylabel('\Delta PI code');
grid on;
xlabel('64-UI block index');
title(sprintf('CDR control: Kp = %.4g, Ki = %.4g', Kp, Ki));
legend('phaseError', 'deltaCode', 'Location', 'best');

exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);

result = struct();
result.WaveformCsv = waveformCsv;
result.SamplesPerUI = samplesPerUI;
result.NumUiUsed = blockSize * numBlocks;
result.SampleInterval = sampleInterval;
result.LevelCenter = levelCenter;
result.Threshold = threshold;
result.ReferenceDataPhase = referenceDataPhase;
result.ReferenceEdgePhase = referenceEdgePhase;
result.PdLockPhase = pdLockPhase;
result.PdMeanDecision = pdMeanDecision;
result.PdValidCount = pdValidCount;
result.Kp = Kp;
result.Ki = Ki;
result.SampleIndexForBlock = sampleIndexForBlock;
result.NextLocalIndexFloat = nextLocalIndexFloat;
result.PhaseErrorSample = phaseErrorSample;
result.PhaseError = phaseError;
result.DeltaCode = deltaCode;
result.ValidCount = validCount;
result.PiCode = piCode;
result.FigurePath = figurePath;

fprintf('test_cdr_top_ctle_waveform passed.\n');
fprintf('PAM4 centers: %s V.\n', mat2str(levelCenter, 5));
fprintf('PAM4 thresholds: %s V.\n', mat2str(threshold, 5));
fprintf('Reference data/edge phase: %d / %d samples.\n', ...
    referenceDataPhase, referenceEdgePhase);
fprintf('BBPD statistical lock phase: %d samples.\n', pdLockPhase);
fprintf('Steady-state phase range: %.3f to %.3f samples.\n', ...
    min(steadyStatePhase), max(steadyStatePhase));
fprintf('Mean steady-state phase error: %.3f samples.\n', ...
    mean(steadyStateError));
fprintf('Selected transition count: %d of %d UI.\n', ...
    sum(validCount), blockSize * numBlocks);
fprintf('Saved PNG: %s\n', figurePath);
end

function levelCenter = estimatePam4Centers(sample)
% estimatePam4Centers  Deterministic one-dimensional four-level clustering.

levelCenter = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    distance = abs(sample(:) - levelCenter);
    [~, clusterIndex] = min(distance, [], 2);
    updatedCenter = levelCenter;
    for levelIndex = 1:4
        levelSample = sample(clusterIndex == levelIndex);
        assert(~isempty(levelSample), ...
            'PAM4 level clustering produced an empty level.');
        updatedCenter(levelIndex) = mean(levelSample);
    end
    updatedCenter = sort(updatedCenter);
    if max(abs(updatedCenter - levelCenter)) < 1e-12
        break;
    end
    levelCenter = updatedCenter;
end
levelCenter = sort(levelCenter);
end

function dataSymbol = slicePam4(sampleValue, threshold)
% slicePam4  Apply three calibrated PAM4 thresholds.

dataSymbol = double(sampleValue > threshold(1)) + ...
    double(sampleValue > threshold(2)) + ...
    double(sampleValue > threshold(3));
end

function [meanDecision, validCount] = measurePdCharacteristic( ...
        voltage, threshold, samplesPerUI, startUi, numUi)
% measurePdCharacteristic  Measure the PAM4 BBPD S-curve versus phase.

pd = cdr_pd('pam4', 1);
meanDecision = zeros(1, samplesPerUI);
validCount = zeros(1, samplesPerUI);
uiIndex = startUi + (0:numUi - 1);
for phase = 0:samplesPerUI - 1
    edgeIndex = uiIndex * samplesPerUI + phase + 1;
    dataIndex = edgeIndex + samplesPerUI / 2;
    previousDataIndex = (startUi - 1) * samplesPerUI + ...
        phase + samplesPerUI / 2 + 1;
    dataCurr = slicePam4(voltage(dataIndex), threshold);
    previousSymbol = slicePam4(voltage(previousDataIndex), threshold);
    dataPrev = [previousSymbol dataCurr(1:end - 1)];
    edgeBit = voltage(edgeIndex) > threshold(2);
    [decision, valid] = pd.bbpdFast(dataPrev, edgeBit, dataCurr);
    validCount(phase + 1) = sum(valid);
    meanDecision(phase + 1) = sum(double(decision)) / ...
        max(validCount(phase + 1), 1);
end
end

function errorSample = wrapSampleError(errorSample, samplesPerUI)
% wrapSampleError  Wrap sample-domain phase error to half a UI.

errorSample = mod(errorSample + samplesPerUI / 2, samplesPerUI) - ...
    samplesPerUI / 2;
end

function plotCtleEye(voltage, samplesPerUI, referenceEdgePhase, threshold)
% plotCtleEye  Plot a compact two-UI eye referenced to nominal boundaries.

numTrace = 160;
traceLength = 2 * samplesPerUI;
traceStart = (0:numTrace - 1) * traceLength + 1;
hold on;
for traceIndex = 1:numTrace
    index = traceStart(traceIndex) + (0:traceLength - 1);
    plot((0:traceLength - 1) / samplesPerUI, voltage(index), ...
        'Color', [0.15 0.4 0.85 0.12], 'LineWidth', 0.5);
end
xline(referenceEdgePhase / samplesPerUI, ...
    'r--', 'LineWidth', 1.2);
xline(1 + referenceEdgePhase / samplesPerUI, ...
    'r--', 'LineWidth', 1.2, 'HandleVisibility', 'off');
for thresholdIndex = 1:numel(threshold)
    yline(threshold(thresholdIndex), 'k:', ...
        'HandleVisibility', 'off');
end
grid on;
xlim([0 2]);
xlabel('Time from nominal UI boundary (UI)');
ylabel('CTLE voltage (V)');
title(['CTLE eye: red dashed line is offline reference edge; ' ...
    'black dotted lines are slicer thresholds']);
end
