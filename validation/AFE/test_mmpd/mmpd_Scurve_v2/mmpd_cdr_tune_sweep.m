function result = mmpd_cdr_tune_sweep
%MMPD_CDR_TUNE_SWEEP Parameter sweep to find Kp/Ki/slew for full-phase lock.
%   Builds the identical TI ADC + zero-forcing FFE + code->symbol pipeline as
%   mmpd_Scurve_v2_cdr.m once, caches the per-block waveforms, then runs the
%   manual closed loop (classic live MM detector -> cdr_loop PI -> cdr_pi) for
%   a grid of (Kp, Ki, maxDeltaCode, maxIterations) values and reports how many
%   of the 16 initial phases lock to the eye center (index 78). The live MM
%   detector has multiple stable zeros, so this sweep probes whether stronger
%   loop drive / slew lets the loop escape the shallow false wells into the
%   deep true well.

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
numBitPi = 7;
errorSign = 1;
initialPhaseList = 0:8:(samplesPerUI - 1);
lockTolerance = 2;
lockHold = 20;

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

% --- Parameter grid ------------------------------------------------------
kpList = [0.6 1.5 3.0 6.0];
kiList = [0.0 0.02 0.1];
maxDeltaList = [1 2 4];
maxIterations = 1500;

numInitialPhase = numel(initialPhaseList);
reportPath = fullfile(resultDir, 'mmpd_cdr_tune_sweep.txt');
fid = fopen(reportPath, 'w');
fprintf(fid, 'CDR Kp/Ki/slew sweep (live MM detector, %d blocks/phase)\n', maxIterations);
fprintf(fid, '%6s %6s %6s   %7s   %s\n', 'Kp', 'Ki', 'dMax', 'locked', 'finalIndex per init');
fprintf('%6s %6s %6s   %7s\n', 'Kp', 'Ki', 'dMax', 'locked');

bestLocked = -1;
bestCombo = [NaN NaN NaN];
records = {};
for kp = kpList
    for ki = kiList
        for dMax = maxDeltaList
            loopModel = cdr_loop(kp, ki, -Inf, Inf, dMax);
            piModel = cdr_pi(numBitPi, samplesPerUI);
            piModel.resetNonideal();

            finalIndex = zeros(1, numInitialPhase);
            lockedFlag = false(1, numInitialPhase);
            for phaseIdx = 1:numInitialPhase
                initialPhase = initialPhaseList(phaseIdx);
                ffeLoop = cdr_ffe(coefficients, preTapCount);
                ffeLoop.resetState();
                loopModel.resetState();
                piModel.resetState();
                piModel.setCode(initialPhase);
                currentPhaseFloat = initialPhase;
                holdCount = 0;
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
                    offset = mod(currentPhase - dataPhase + samplesPerUI / 2, samplesPerUI) - samplesPerUI / 2;
                    if abs(offset) <= lockTolerance
                        holdCount = holdCount + 1;
                        if holdCount >= lockHold
                            lockedFlag(phaseIdx) = true;
                        end
                    else
                        holdCount = 0;
                    end
                end
                finalIndex(phaseIdx) = mod(round(currentPhaseFloat), samplesPerUI);
            end
            nLocked = sum(lockedFlag);
            fprintf('%6.2f %6.3f %6d   %7d\n', kp, ki, dMax, nLocked);
            fprintf(fid, '%6.2f %6.3f %6d   %7d   %s\n', kp, ki, dMax, nLocked, mat2str(finalIndex));
            records{end + 1} = struct('Kp', kp, 'Ki', ki, 'MaxDelta', dMax, ...
                'Locked', nLocked, 'FinalIndex', finalIndex); %#ok<AGROW>
            if nLocked > bestLocked
                bestLocked = nLocked;
                bestCombo = [kp ki dMax];
            end
        end
    end
end
fprintf(fid, '\nBest: Kp=%.2f Ki=%.3f dMax=%d  locked=%d/%d\n', ...
    bestCombo(1), bestCombo(2), bestCombo(3), bestLocked, numInitialPhase);
fclose(fid);

fprintf('BEST Kp=%.2f Ki=%.3f dMax=%d locked=%d/%d\n', ...
    bestCombo(1), bestCombo(2), bestCombo(3), bestLocked, numInitialPhase);
fprintf('Saved sweep report: %s\n', reportPath);

result = struct();
result.Records = records;
result.BestCombo = bestCombo;
result.BestLocked = bestLocked;
result.ReportPath = reportPath;
end

function phaseError = classicMmError(ffeSamples, codeToSymbol, symbolLevels)
sampled = reshape(codeToSymbol(ffeSamples), 1, []);
if numel(sampled) < 2
    phaseError = 0;
    return;
end
[~, decisionIndex] = min(abs(sampled(:) - symbolLevels), [], 2);
decision = reshape(symbolLevels(decisionIndex), 1, []);
slicerError = sampled - decision;
timingError = decision(1:end - 1) .* slicerError(2:end) - ...
    decision(2:end) .* slicerError(1:end - 1);
phaseError = mean(timingError);
end

function value = getPulse(pulse, lagRange, mainLag, cursor)
targetLag = cursor + mainLag;
idx = find(lagRange == targetLag, 1);
if isempty(idx)
    value = 0;
else
    value = pulse(idx);
end
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
