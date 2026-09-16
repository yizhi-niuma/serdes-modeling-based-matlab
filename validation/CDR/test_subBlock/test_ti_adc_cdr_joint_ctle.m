function result = test_ti_adc_cdr_joint_ctle
%TEST_TI_ADC_CDR_JOINT_CTLE Joint TI-ADC and PAM4 MMPD CDR validation.
%   CTLE waveform -> 64-lane 7-bit TI ADC -> code-domain DSP decision
%   (PAM4 data and binary error bit) -> MMPD -> voter -> loop -> PI.
%   The PI phase used by one 64-UI block is updated for the next block.

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(validationDir));
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
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
startUi = 2;
numBits = 7;
adcLow = -0.3;
adcHigh = 0.3;
sarPerTah = 8;
inputMargin = samplesPerUI;

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

% Calibrate the DSP in the digital-code domain. Voltage is used only to
% find the offline maximum-power phase; all centers/thresholds consumed by
% the DSP are estimated from ADC output codes.
phasePower = zeros(1, samplesPerUI);
calibrationUi = 0:4095;
for phase = 0:samplesPerUI - 1
    index = calibrationUi * samplesPerUI + phase + 1;
    phasePower(phase + 1) = mean(voltage(index).^2);
end
[~, referenceDataPhaseIndex] = max(phasePower);
referenceDataPhase = referenceDataPhaseIndex - 1;
calibrationIndex = calibrationUi * samplesPerUI + referenceDataPhase + 1;
calibrationAdc = sar_adc_core(adcLow, adcHigh, numBits);
calibrationCode = calibrationAdc.convertVectorFast(voltage(calibrationIndex));
codeCenter = estimatePam4Centers(double(calibrationCode));
codeThreshold = (codeCenter(1:3) + codeCenter(2:4)) / 2;

% ADC-quantized S-curve is the reference for this joint simulation, so the
% lock target includes quantizer effects rather than reusing analog slicing.
[pdMeanDecision, pdValidCount] = measureCodeMmpdCharacteristic( ...
    voltage, adcLow, adcHigh, numBits, codeThreshold, codeCenter, ...
    samplesPerUI, startUi, blockSize * numBlocks);
phaseCandidate = 0:samplesPerUI - 1;
distanceFromReference = abs(wrapSampleError( ...
    phaseCandidate - referenceDataPhase, samplesPerUI));
lockMask = distanceFromReference <= samplesPerUI / 4 & ...
    pdValidCount >= 0.05 * blockSize * numBlocks;
lockScore = abs(pdMeanDecision);
lockScore(~lockMask) = Inf;
[~, lockIndex] = min(lockScore);
adcMmpdLockPhase = lockIndex - 1;
assert(isfinite(lockScore(lockIndex)), 'No usable ADC MMPD lock phase was found.');

% MMPD is a tracking detector. Start eight waveform samples from its
% measured lock point, consistent with the existing CTLE MMPD validation.
initialPhase = mod(adcMmpdLockPhase - 8, samplesPerUI);
Kp = 0.5;
Ki = 0.005;
polarity = 1;

adc = ti_adc_top(blockSize, adcLow, adcHigh, numBits, ...
    sarPerTah, samplesPerUI);
adc.setInputMargin(inputMargin);
adc.resetState();
pd = cdr_pd('pam4', polarity);
voter = cdr_voter('constant', blockSize, 8);
loopFilter = cdr_loop(Kp, Ki, -2, 2, 1);
piModel = cdr_pi(8, samplesPerUI);
piModel.resetNonideal();
piModel.setCode(round(initialPhase * piModel.NumCode / samplesPerUI));
currentLocalIndex = piModel.getLocalIndex();

previousIndex = (startUi - 1) * samplesPerUI + initialPhase + 1;
previousCode = calibrationAdc.convertInstantFast(voltage(previousIndex));
[previousData, previousError] = decisionFromCode( ...
    previousCode, codeThreshold, codeCenter);

samplePhase = zeros(1, numBlocks);
phaseError = zeros(1, numBlocks);
deltaCode = zeros(1, numBlocks);
validCount = zeros(1, numBlocks);
adcCode = zeros(numBlocks, blockSize);
dataDecision = zeros(numBlocks, blockSize);
errorDecision = false(numBlocks, blockSize);

nominalLength = (blockSize - 1) * samplesPerUI + 1;
physicalLane = 1:blockSize;
phaseIndex = floor((physicalLane - 1) / sarPerTah) + 1;
sarIndexInPhase = mod(physicalLane - 1, sarPerTah) + 1;
timeOrderIndex = (sarIndexInPhase - 1) * (blockSize / sarPerTah) + phaseIndex;
for blockIndex = 1:numBlocks
    samplePhase(blockIndex) = currentLocalIndex;
    localPhase = mod(round(currentLocalIndex), samplesPerUI);
    firstUi = startUi + (blockIndex - 1) * blockSize;
    nominalStart = firstUi * samplesPerUI + 1;
    localStart = nominalStart - inputMargin;
    localStop = nominalStart + nominalLength - 1 + inputMargin;
    assert(localStart >= 1 && localStop <= numel(voltage), ...
        'CTLE fixture does not contain the required local ADC block margin.');
    localWaveform = voltage(localStart:localStop);

    physicalCode = adc.convertOneBlockFast(localWaveform, localPhase + 1);
    codeBlock = zeros(1, blockSize);
    codeBlock(timeOrderIndex) = physicalCode;
    [dataBlock, errorBlock] = decisionFromCode( ...
        codeBlock, codeThreshold, codeCenter);
    dataPrev = [previousData dataBlock(1:end - 1)];
    errorPrev = [previousError errorBlock(1:end - 1)];
    [decision, valid] = pd.mmpdFast( ...
        dataPrev, errorPrev, dataBlock, errorBlock);
    phaseError(blockIndex) = double(voter.voteFast(decision));
    deltaCode(blockIndex) = loopFilter.updateFast(phaseError(blockIndex));
    currentLocalIndex = piModel.updateFast(deltaCode(blockIndex));

    adcCode(blockIndex, :) = codeBlock;
    dataDecision(blockIndex, :) = dataBlock;
    errorDecision(blockIndex, :) = errorBlock;
    validCount(blockIndex) = sum(valid);
    previousData = dataBlock(end);
    previousError = errorBlock(end);
end

phaseErrorSample = wrapSampleError(samplePhase - adcMmpdLockPhase, samplesPerUI);
steady = numBlocks - 15:numBlocks;
steadyMeanError = mean(phaseErrorSample(steady));
steadySpan = max(samplePhase(steady)) - min(samplePhase(steady));
steadyDrift = abs(mean(diff(samplePhase(steady))));

fprintf(['TI ADC + CDR diagnostic: power phase=%d, ADC MMPD lock=%d, ' ...
    'initial=%d, final=%.3f, steady mean=%.3f, span=%.3f, drift=%.3f, valid=%d.\n'], ...
    referenceDataPhase, adcMmpdLockPhase, initialPhase, samplePhase(end), ...
    steadyMeanError, steadySpan, steadyDrift, sum(validCount));

assert(all(adcCode(:) >= 0 & adcCode(:) <= 2^numBits - 1), ...
    'TI ADC produced an out-of-range digital code.');
assert(all(ismember(dataDecision(:), 0:3)), ...
    'DSP data decision is outside PAM4 symbol range.');
assert(sum(validCount) >= 0.05 * blockSize * numBlocks, ...
    'Too few MMPD transitions were available after ADC quantization.');
assert(any(phaseError > 0) && any(phaseError < 0), ...
    'CDR control did not reverse direction around the lock point.');
assert(abs(steadyMeanError) <= 3, ...
    'Mean steady-state phase error exceeds three waveform samples.');
assert(steadySpan <= 8, ...
    'Steady-state phase span exceeds eight waveform samples.');
assert(steadyDrift <= 0.25, ...
    'Steady-state phase has excessive residual drift.');

figurePath = fullfile(resultDir, 'ti_adc_cdr_joint_ctle_convergence.png');
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1150 980]);
tiled = tiledlayout(fig, 5, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tiled, 'CTLE -> 7-bit 64-lane TI ADC -> DSP data/err -> PAM4 MMPD CDR');

nexttile;
plot(0:samplesPerUI - 1, pdMeanDecision, 'b-', 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
xline(referenceDataPhase, 'r:', 'LineWidth', 1.2);
xline(adcMmpdLockPhase, 'm--', 'LineWidth', 1.2);
grid on;
xlim([0 samplesPerUI - 1]);
ylabel('mean decision');
title('ADC-code-domain MMPD S-curve');
legend('mean valid decision', 'zero', 'power data phase', ...
    'ADC MMPD lock', 'Location', 'best');

blockAxis = 1:numBlocks;
nexttile;
plot(blockAxis, samplePhase, 'b-o', 'LineWidth', 1.2, 'MarkerSize', 3);
hold on;
yline(referenceDataPhase, 'r:');
yline(adcMmpdLockPhase, 'm--');
grid on;
ylabel('phase (sample)');
title('PI sampling phase used by each 64-UI ADC block');

nexttile;
stairs(blockAxis, phaseErrorSample, 'LineWidth', 1.2);
hold on;
yline(0, 'k--');
grid on;
ylabel('error (sample)');
title('Wrapped phase error relative to ADC MMPD lock');

nexttile;
bar(blockAxis, validCount, 0.8, 'FaceColor', [0.2 0.6 0.35], 'EdgeColor', 'none');
grid on;
ylim([0 blockSize]);
ylabel('valid/UI');
title('Valid code-domain MMPD transitions per block');

nexttile;
yyaxis left;
stairs(blockAxis, phaseError, 'LineWidth', 1.2);
ylabel('voter output');
yyaxis right;
stairs(blockAxis, deltaCode, '--', 'LineWidth', 1.2);
ylabel('\Delta PI code');
grid on;
xlabel('64-UI block index');
title(sprintf('CDR control: Kp=%.4g, Ki=%.4g', Kp, Ki));

exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);

result = struct();
result.WaveformCsv = waveformCsv;
result.AdcRange = [adcLow adcHigh];
result.AdcBits = numBits;
result.AdcInputOverdriveFraction = overdriveFraction;
result.CodeCenter = codeCenter;
result.CodeThreshold = codeThreshold;
result.ReferenceDataPhase = referenceDataPhase;
result.AdcMmpdLockPhase = adcMmpdLockPhase;
result.InitialPhase = initialPhase;
result.SamplePhase = samplePhase;
result.PhaseErrorSample = phaseErrorSample;
result.PhaseError = phaseError;
result.DeltaCode = deltaCode;
result.ValidCount = validCount;
result.AdcCode = adcCode;
result.DataDecision = dataDecision;
result.ErrorDecision = errorDecision;
result.SteadyMeanError = steadyMeanError;
result.SteadySpan = steadySpan;
result.SteadyDrift = steadyDrift;
result.FigurePath = figurePath;

fprintf(['TI ADC + CDR passed: power phase=%d, ADC MMPD lock=%d, ' ...
    'initial=%d, final=%.3f, steady mean=%.3f, span=%.3f, valid=%d.\n'], ...
    referenceDataPhase, adcMmpdLockPhase, initialPhase, samplePhase(end), ...
    steadyMeanError, steadySpan, sum(validCount));
fprintf('DSP code centers: %s; thresholds: %s.\n', ...
    mat2str(codeCenter, 5), mat2str(codeThreshold, 5));
fprintf('ADC input overdrive fraction: %.6g.\n', overdriveFraction);
fprintf('Saved PNG: %s\n', figurePath);
end

function [meanDecision, validCount] = measureCodeMmpdCharacteristic( ...
        voltage, adcLow, adcHigh, numBits, threshold, center, ...
        samplesPerUI, startUi, numUi)
adc = sar_adc_core(adcLow, adcHigh, numBits);
pd = cdr_pd('pam4', 1);
meanDecision = zeros(1, samplesPerUI);
validCount = zeros(1, samplesPerUI);
uiIndex = startUi + (0:numUi - 1);
for phase = 0:samplesPerUI - 1
    index = uiIndex * samplesPerUI + phase + 1;
    previousIndex = (startUi - 1) * samplesPerUI + phase + 1;
    code = adc.convertVectorFast(voltage(index));
    previousCode = adc.convertInstantFast(voltage(previousIndex));
    [dataCurr, errorCurr] = decisionFromCode(code, threshold, center);
    [previousData, previousError] = decisionFromCode( ...
        previousCode, threshold, center);
    dataPrev = [previousData dataCurr(1:end - 1)];
    errorPrev = [previousError errorCurr(1:end - 1)];
    [decision, valid] = pd.mmpdFast( ...
        dataPrev, errorPrev, dataCurr, errorCurr);
    validCount(phase + 1) = sum(valid);
    meanDecision(phase + 1) = sum(double(decision)) / max(validCount(phase + 1), 1);
end
end

function [symbol, errorBit] = decisionFromCode(code, threshold, center)
code = double(code);
symbol = double(code > threshold(1)) + double(code > threshold(2)) + ...
    double(code > threshold(3));
symbolCenter = center(symbol + 1);
negativeLevel = symbol <= 1;
errorBit = (negativeLevel & code > symbolCenter) | ...
    (~negativeLevel & code < symbolCenter);
end

function center = estimatePam4Centers(sample)
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

function errorSample = wrapSampleError(errorSample, samplesPerUI)
errorSample = mod(errorSample + samplesPerUI / 2, samplesPerUI) - samplesPerUI / 2;
end
