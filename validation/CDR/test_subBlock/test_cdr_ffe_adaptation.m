function result = test_cdr_ffe_adaptation
% test_cdr_ffe_adaptation  Supervised-to-DD block-LMS validation at phase 20.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(fileparts(testDir)));
addpath(fullfile(repoRoot, 'src', 'ADC', 'TI_ADC'));
addpath(fullfile(repoRoot, 'src', 'CDR'));

fixturePath = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr', 'result', 'channel_ctle_cosim', 'channel_ctle.mat');
resultDir = fullfile(testDir, 'result', 'test_cdr_ffe_adaptation');
assert(isfile(fixturePath), 'The Channel+CTLE fixture is missing.');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

cacheFile = matfile(fixturePath);
samplesPerUi = double(cacheFile.samplePerSymbol);
numCachedSymbols = double(cacheFile.numSymbols);
assert(samplesPerUi == 128, 'The fixture must contain 128 waveform samples per UI.');

phaseZeroBased = 20;
phaseMatlabIndex = phaseZeroBased + 1;
adcLaneCount = 64;
adcSarPerTah = 8;
adcResolutionBits = 7;
adcLow = -4;
adcHigh = 4;
adcZeroCode = 2^(adcResolutionBits - 1);
adcInputMargin = samplesPerUi;
blockSize = 64;
numTargetUi = 16384;
numUpdates = numTargetUi / blockSize;
baseUi = 512;
postTapCount = 3;
preTapCount = 2;
mainTapIndex = 3;
initialCoefficients = [0 0 1 0 0 0];
initialMuList = [1e-5 3e-5 1e-4 3e-4 1e-3 3e-3 1e-2 3e-2];
alignmentDelayRange = -64:256;
alignmentIgnoreUi = 256;
alignmentCountUi = 4096;
scaleTrainingUi = 4096;
primaryTrainingUi = 8192;
fallbackTrainingUi = 12288;
tailBlockCount = 16;

thresholds = struct();
thresholds.SupervisedTailToHeadRatioMax = 0.85;
thresholds.SupervisedTailToPreviousRatioMax = 1.10;
thresholds.SupervisedCoefficientSpanMax = 0.05;
thresholds.SupervisedTailDeltaMax = 0.005;
thresholds.DdCoefficientSpanMax = 0.08;
thresholds.DdTailDeltaMax = 0.01;
thresholds.DdSerMax = 0.15;
thresholds.DdTruthMseMax = 1.25;
thresholds.DdDecisionMseMax = 0.35;
thresholds.DdLevelOpeningMin = 1.0;

assert(mod(numTargetUi, blockSize) == 0, 'The target length must contain complete LMS blocks.');
assert(baseUi > postTapCount, 'baseUi must provide past-sample context.');
assert(baseUi + numTargetUi + preTapCount < numCachedSymbols, 'The fixture does not contain the requested target and context UI.');

[timeOrderedCode, sampleUi] = quantizeFixedPhase(cacheFile, baseUi - postTapCount, numTargetUi + postTapCount + preTapCount, phaseMatlabIndex, samplesPerUi, adcLaneCount, adcSarPerTah, adcResolutionBits, adcLow, adcHigh, adcInputMargin);
centeredCode = timeOrderedCode - adcZeroCode;
pam4Symbols = double(cacheFile.pam4Symbols);
[alignmentDelayUi, alignmentCorrelation, alignmentCorrelationTrace] = findSymbolAlignment(centeredCode, sampleUi, pam4Symbols, alignmentDelayRange, alignmentIgnoreUi, alignmentCountUi);

scaleUse = postTapCount + (1:scaleTrainingUi);
scaleSymbolIndex = sampleUi(scaleUse) - alignmentDelayUi + 1;
scaleKnown = pam4Symbols(scaleSymbolIndex);
scaleInput = centeredCode(scaleUse);
codeToPam4Scale = sum(scaleInput .* scaleKnown) / sum(scaleInput .^ 2);
assert(isfinite(codeToPam4Scale) && codeToPam4Scale ~= 0, 'The fixed code-to-PAM4 scale is invalid.');
scaledCode = codeToPam4Scale * centeredCode;

targetCodeIndex = postTapCount + (1:numTargetUi);
targetSampleUi = sampleUi(targetCodeIndex);
knownSymbolIndex = targetSampleUi - alignmentDelayUi + 1;
knownTarget = pam4Symbols(knownSymbolIndex);

primaryTrainingBlocks = primaryTrainingUi / blockSize;
[muMetrics, acceptedIndex] = scanMuList(initialMuList, scaledCode, knownTarget, primaryTrainingBlocks, blockSize, initialCoefficients, mainTapIndex, thresholds, tailBlockCount);
fallbackUsed = isempty(acceptedIndex);
if fallbackUsed
    trainingUi = fallbackTrainingUi;
    trainingBlocks = fallbackTrainingUi / blockSize;
    [muMetrics, acceptedIndex] = scanMuList(initialMuList, scaledCode, knownTarget, trainingBlocks, blockSize, initialCoefficients, mainTapIndex, thresholds, tailBlockCount);
else
    trainingUi = primaryTrainingUi;
    trainingBlocks = primaryTrainingBlocks;
end
assert(~isempty(acceptedIndex), 'No mu met the supervised convergence criteria, including the documented fallback split.');

acceptedScore = [muMetrics(acceptedIndex).SelectionScore];
[~, localBest] = min(acceptedScore);
selectedIndex = acceptedIndex(localBest);
selectedMu = muMetrics(selectedIndex).Mu;
selectedRun = runAdaptation(selectedMu, scaledCode, knownTarget, trainingBlocks, blockSize, initialCoefficients, mainTapIndex, tailBlockCount);

ddAcceptance = struct();
ddAcceptance.Finite = selectedRun.Finite;
ddAcceptance.MainTapFixed = selectedRun.MainTapFixed;
ddAcceptance.CoefficientSpan = selectedRun.DdCoefficientSpan;
ddAcceptance.CoefficientSpanPass = selectedRun.DdCoefficientSpan <= thresholds.DdCoefficientSpanMax;
ddAcceptance.TailDeltaMax = selectedRun.DdTailDeltaMax;
ddAcceptance.TailDeltaPass = selectedRun.DdTailDeltaMax <= thresholds.DdTailDeltaMax;
ddAcceptance.Ser = selectedRun.DdSer;
ddAcceptance.SerPass = selectedRun.DdSer <= thresholds.DdSerMax;
ddAcceptance.TruthMse = selectedRun.DdTruthMse;
ddAcceptance.TruthMsePass = selectedRun.DdTruthMse <= thresholds.DdTruthMseMax;
ddAcceptance.DecisionMse = selectedRun.DdDecisionMse;
ddAcceptance.DecisionMsePass = selectedRun.DdDecisionMse <= thresholds.DdDecisionMseMax;
ddAcceptance.LevelOpening = selectedRun.DdLevelOpening;
ddAcceptance.LevelOpeningPass = selectedRun.DdLevelOpening >= thresholds.DdLevelOpeningMin;
ddAcceptance.Pass = ddAcceptance.Finite && ddAcceptance.MainTapFixed && ddAcceptance.CoefficientSpanPass && ddAcceptance.TailDeltaPass && ddAcceptance.SerPass && ddAcceptance.TruthMsePass && ddAcceptance.DecisionMsePass && ddAcceptance.LevelOpeningPass;

assert(all(isfinite(selectedRun.CoefficientTrace(:))), 'The selected coefficient trace contains nonfinite values.');
assert(all(selectedRun.CoefficientTrace(:, mainTapIndex) == 1), 'The fixed main tap changed during adaptation.');
assert(muMetrics(selectedIndex).SupervisedPass, 'The selected mu did not pass supervised-only selection criteria.');
assert(ddAcceptance.Pass, 'The selected supervised-only mu failed the independent DD acceptance criteria.');

muScanPath = fullfile(resultDir, 'mu_scan.png');
coefficientPath = fullfile(resultDir, 'coefficient_convergence.png');
msePath = fullfile(resultDir, 'mse_convergence.png');
histogramPath = fullfile(resultDir, 'before_after_histogram.png');
plotMuScan(muMetrics, selectedIndex, muScanPath);
plotCoefficientTrace(selectedRun.CoefficientTrace, trainingBlocks, coefficientPath);
plotMseTrace(selectedRun.TruthMseTrace, selectedRun.UpdateMseTrace, trainingBlocks, msePath);
plotBeforeAfter(scaledCode(targetCodeIndex), selectedRun.OutputTrace, knownTarget, trainingBlocks, blockSize, histogramPath);

result = struct();
result.FixturePath = fixturePath;
result.ResultDirectory = resultDir;
result.SamplePerUi = samplesPerUi;
result.PhaseZeroBased = phaseZeroBased;
result.PhaseMatlabIndex = phaseMatlabIndex;
result.AdcLaneCount = adcLaneCount;
result.AdcSarPerTah = adcSarPerTah;
result.AdcResolutionBits = adcResolutionBits;
result.AdcLow = adcLow;
result.AdcHigh = adcHigh;
result.AdcZeroCode = adcZeroCode;
result.AdcInputMargin = adcInputMargin;
result.BaseUi = baseUi;
result.NumTargetUi = numTargetUi;
result.BlockSize = blockSize;
result.NumUpdates = numUpdates;
result.InitialCoefficients = initialCoefficients;
result.MainTapIndex = mainTapIndex;
result.PostTapCount = postTapCount;
result.PreTapCount = preTapCount;
result.AlignmentDelayRange = alignmentDelayRange;
result.AlignmentDelayUi = alignmentDelayUi;
result.AlignmentCorrelation = alignmentCorrelation;
result.AlignmentCorrelationTrace = alignmentCorrelationTrace;
result.CodeToPam4Scale = codeToPam4Scale;
result.ScaleTrainingUi = scaleTrainingUi;
result.TrainingUi = trainingUi;
result.DdUi = numTargetUi - trainingUi;
result.TrainingBlocks = trainingBlocks;
result.DdBlocks = numUpdates - trainingBlocks;
result.FallbackUsed = fallbackUsed;
result.FallbackDefinition = 'Primary 8192 supervised + 8192 DD; fallback 12288 supervised + 4096 DD only if no mu passes supervised criteria.';
result.MuList = initialMuList;
result.MuSelectionRule = 'Select minimum supervised tail MSE among candidates passing finite/main-tap, tail/head MSE, tail/previous MSE, coefficient-span, and delta thresholds. DD metrics are excluded from selection.';
result.MuMetrics = muMetrics;
result.SelectedMu = selectedMu;
result.Thresholds = thresholds;
result.CoefficientTrace = selectedRun.CoefficientTrace;
result.GradientTrace = selectedRun.GradientTrace;
result.DeltaTrace = selectedRun.DeltaTrace;
result.TruthMseTrace = selectedRun.TruthMseTrace;
result.UpdateMseTrace = selectedRun.UpdateMseTrace;
result.SerTrace = selectedRun.SerTrace;
result.FinalCoefficients = selectedRun.FinalCoefficients;
result.SupervisedTailMse = selectedRun.SupervisedTailMse;
result.DdSer = selectedRun.DdSer;
result.DdTruthMse = selectedRun.DdTruthMse;
result.DdDecisionMse = selectedRun.DdDecisionMse;
result.DdLevelCenters = selectedRun.DdLevelCenters;
result.DdLevelOpening = selectedRun.DdLevelOpening;
result.DdAcceptance = ddAcceptance;
result.Pass = ddAcceptance.Pass && muMetrics(selectedIndex).SupervisedPass;
result.MuScanPath = muScanPath;
result.CoefficientPath = coefficientPath;
result.MsePath = msePath;
result.HistogramPath = histogramPath;
resultMatPath = fullfile(resultDir, 'result.mat');
result.ResultMatPath = resultMatPath;
save(resultMatPath, 'result', '-v7.3');

fprintf('CDR FFE adaptation passed: phase=%d, delay=%d UI, corr=%.6f, scale=%.6f, mu=%.6g, fallback=%d.\n', phaseZeroBased, alignmentDelayUi, alignmentCorrelation, codeToPam4Scale, selectedMu, fallbackUsed);
fprintf('Supervised tail MSE=%.6g; DD SER=%.6g, truth MSE=%.6g, decision MSE=%.6g, opening=%.6g.\n', selectedRun.SupervisedTailMse, selectedRun.DdSer, selectedRun.DdTruthMse, selectedRun.DdDecisionMse, selectedRun.DdLevelOpening);
fprintf('Results saved to %s.\n', resultDir);
end

function [timeOrderedCode, sampleUi] = quantizeFixedPhase(cacheFile, firstUi, requestedUi, phaseMatlabIndex, samplesPerUi, adcLaneCount, adcSarPerTah, adcResolutionBits, adcLow, adcHigh, inputMargin)
numBlocks = ceil(requestedUi / adcLaneCount);
quantizedUi = numBlocks * adcLaneCount;
timeOrderedCode = zeros(1, quantizedUi);
sampleUi = firstUi + (0:quantizedUi - 1);
adcModel = ti_adc_top(adcLaneCount, adcLow, adcHigh, adcResolutionBits, adcSarPerTah, samplesPerUi);
adcModel.setInputMargin(inputMargin);
adcModel.resetState();
physicalLane = 1:adcLaneCount;
numTah = adcLaneCount / adcSarPerTah;
lanePhaseIndex = floor((physicalLane - 1) / adcSarPerTah) + 1;
laneSarIndex = mod(physicalLane - 1, adcSarPerTah) + 1;
timeOrderIndex = (laneSarIndex - 1) * numTah + lanePhaseIndex;
nominalBlockLength = (adcLaneCount - 1) * samplesPerUi + 1;
for blockIndex = 1:numBlocks
    blockFirstUi = firstUi + (blockIndex - 1) * adcLaneCount;
    waveformFirst = blockFirstUi * samplesPerUi + 1 - inputMargin;
    waveformLast = blockFirstUi * samplesPerUi + nominalBlockLength + inputMargin;
    assert(waveformFirst >= 1, 'The ADC local waveform starts before the fixture.');
    localWaveform = double(cacheFile.ctleOutput(1, waveformFirst:waveformLast));
    physicalCode = adcModel.convertOneBlockFast(localWaveform, phaseMatlabIndex);
    codeBlock = zeros(1, adcLaneCount);
    codeBlock(timeOrderIndex) = double(physicalCode);
    traceIndex = (blockIndex - 1) * adcLaneCount + (1:adcLaneCount);
    timeOrderedCode(traceIndex) = codeBlock;
end
timeOrderedCode = timeOrderedCode(1:requestedUi);
sampleUi = sampleUi(1:requestedUi);
end

function [bestDelay, bestCorrelation, correlationTrace] = findSymbolAlignment(centeredCode, sampleUi, pam4Symbols, delayRange, ignoreUi, countUi)
useIndex = ignoreUi + (1:countUi);
rx = centeredCode(useIndex);
correlationTrace = zeros(size(delayRange));
for delayIndex = 1:numel(delayRange)
    symbolIndex = sampleUi(useIndex) - delayRange(delayIndex) + 1;
    assert(all(symbolIndex >= 1 & symbolIndex <= numel(pam4Symbols)), 'Alignment scan exceeded the symbol fixture.');
    correlationTrace(delayIndex) = normalizedCorrelation(rx, pam4Symbols(symbolIndex));
end
[~, bestIndex] = max(abs(correlationTrace));
bestDelay = delayRange(bestIndex);
bestCorrelation = correlationTrace(bestIndex);
assert(abs(bestCorrelation) >= 0.5, 'The bounded symbol-alignment correlation is too weak.');
end

function value = normalizedCorrelation(x, y)
x = double(x) - mean(x);
y = double(y) - mean(y);
value = sum(x .* y) / sqrt(sum(x .^ 2) * sum(y .^ 2));
end

function [metrics, acceptedIndex] = scanMuList(muList, inputStream, knownTarget, trainingBlocks, blockSize, initialCoefficients, mainTapIndex, thresholds, tailBlockCount)
metrics = repmat(struct(), 1, numel(muList));
for muIndex = 1:numel(muList)
    run = runAdaptation(muList(muIndex), inputStream, knownTarget, trainingBlocks, blockSize, initialCoefficients, mainTapIndex, tailBlockCount);
    tailToHeadRatio = run.SupervisedTailMse / run.SupervisedHeadMse;
    tailToPreviousRatio = run.SupervisedTailMse / run.SupervisedPreviousMse;
    supervisedPass = run.Finite && run.MainTapFixed && tailToHeadRatio <= thresholds.SupervisedTailToHeadRatioMax && tailToPreviousRatio <= thresholds.SupervisedTailToPreviousRatioMax && run.SupervisedCoefficientSpan <= thresholds.SupervisedCoefficientSpanMax && run.SupervisedTailDeltaMax <= thresholds.SupervisedTailDeltaMax;
    metrics(muIndex).Mu = muList(muIndex);
    metrics(muIndex).Finite = run.Finite;
    metrics(muIndex).MainTapFixed = run.MainTapFixed;
    metrics(muIndex).SupervisedHeadMse = run.SupervisedHeadMse;
    metrics(muIndex).SupervisedPreviousMse = run.SupervisedPreviousMse;
    metrics(muIndex).SupervisedTailMse = run.SupervisedTailMse;
    metrics(muIndex).TailToHeadRatio = tailToHeadRatio;
    metrics(muIndex).TailToPreviousRatio = tailToPreviousRatio;
    metrics(muIndex).SupervisedCoefficientSpan = run.SupervisedCoefficientSpan;
    metrics(muIndex).SupervisedTailDeltaMax = run.SupervisedTailDeltaMax;
    metrics(muIndex).SupervisedPass = supervisedPass;
    metrics(muIndex).SelectionScore = run.SupervisedTailMse;
end
acceptedIndex = find([metrics.SupervisedPass]);
end

function run = runAdaptation(mu, inputStream, knownTarget, trainingBlocks, blockSize, initialCoefficients, mainTapIndex, tailBlockCount)
numUpdates = numel(knownTarget) / blockSize;
ffeModel = cdr_ffe(initialCoefficients, mainTapIndex - 1);
adaptationLoop = cdr_ffe_loop(mu, numel(initialCoefficients), mainTapIndex, blockSize);
coefficientTrace = zeros(numUpdates + 1, numel(initialCoefficients));
gradientTrace = zeros(numUpdates, numel(initialCoefficients));
deltaTrace = zeros(numUpdates, numel(initialCoefficients));
truthMseTrace = zeros(1, numUpdates);
updateMseTrace = zeros(1, numUpdates);
serTrace = zeros(1, numUpdates);
outputTrace = zeros(1, numel(knownTarget));
decisionTrace = zeros(1, numel(knownTarget));
coefficientTrace(1, :) = ffeModel.Coefficients;
for blockIndex = 1:numUpdates
    windowIndex = (blockIndex - 1) * blockSize + (1:blockSize + 5);
    targetIndex = (blockIndex - 1) * blockSize + (1:blockSize);
    [outputBlock, dataRegressor] = ffeModel.processBlockFast(inputStream(windowIndex));
    knownBlock = knownTarget(targetIndex);
    decisionBlock = slicePam4(outputBlock);
    if blockIndex <= trainingBlocks
        desiredBlock = knownBlock;
    else
        desiredBlock = decisionBlock;
    end
    errorBlock = desiredBlock - outputBlock;
    gradientTrace(blockIndex, :) = errorBlock * dataRegressor / blockSize;
    deltaCoefficients = adaptationLoop.updateFast(dataRegressor, errorBlock);
    ffeModel.applyCoefficientDelta(deltaCoefficients);
    deltaTrace(blockIndex, :) = deltaCoefficients;
    coefficientTrace(blockIndex + 1, :) = ffeModel.Coefficients;
    truthMseTrace(blockIndex) = mean((knownBlock - outputBlock) .^ 2);
    updateMseTrace(blockIndex) = mean(errorBlock .^ 2);
    serTrace(blockIndex) = mean(decisionBlock ~= knownBlock);
    outputTrace(targetIndex) = outputBlock;
    decisionTrace(targetIndex) = decisionBlock;
end
headIndex = 1:tailBlockCount;
tailIndex = trainingBlocks - tailBlockCount + 1:trainingBlocks;
previousIndex = trainingBlocks - 2 * tailBlockCount + 1:trainingBlocks - tailBlockCount;
supervisedCoefficientWindow = coefficientTrace(trainingBlocks - tailBlockCount + 2:trainingBlocks + 1, :);
supervisedDeltaWindow = deltaTrace(tailIndex, :);
ddBlockIndex = trainingBlocks + 1:numUpdates;
ddSampleIndex = trainingBlocks * blockSize + 1:numel(knownTarget);
ddTailBlockIndex = numUpdates - tailBlockCount + 1:numUpdates;
ddCoefficientWindow = coefficientTrace(numUpdates - tailBlockCount + 2:numUpdates + 1, :);
levelCenters = calculateKnownLevelCenters(outputTrace(ddSampleIndex), knownTarget(ddSampleIndex));
run = struct();
run.Finite = all(isfinite(coefficientTrace(:))) && all(isfinite(gradientTrace(:))) && all(isfinite(deltaTrace(:))) && all(isfinite(outputTrace));
run.MainTapFixed = all(coefficientTrace(:, mainTapIndex) == 1) && all(deltaTrace(:, mainTapIndex) == 0);
run.CoefficientTrace = coefficientTrace;
run.GradientTrace = gradientTrace;
run.DeltaTrace = deltaTrace;
run.TruthMseTrace = truthMseTrace;
run.UpdateMseTrace = updateMseTrace;
run.SerTrace = serTrace;
run.OutputTrace = outputTrace;
run.DecisionTrace = decisionTrace;
run.FinalCoefficients = coefficientTrace(end, :);
run.SupervisedHeadMse = mean(truthMseTrace(headIndex));
run.SupervisedPreviousMse = mean(truthMseTrace(previousIndex));
run.SupervisedTailMse = mean(truthMseTrace(tailIndex));
run.SupervisedCoefficientSpan = max(max(supervisedCoefficientWindow, [], 1) - min(supervisedCoefficientWindow, [], 1));
run.SupervisedTailDeltaMax = max(abs(supervisedDeltaWindow(:)));
run.DdCoefficientSpan = max(max(ddCoefficientWindow, [], 1) - min(ddCoefficientWindow, [], 1));
run.DdTailDeltaMax = max(abs(deltaTrace(ddTailBlockIndex, :)), [], 'all');
run.DdSer = mean(serTrace(ddBlockIndex));
run.DdTruthMse = mean(truthMseTrace(ddBlockIndex));
run.DdDecisionMse = mean(updateMseTrace(ddBlockIndex));
run.DdLevelCenters = levelCenters;
run.DdLevelOpening = min(diff(levelCenters));
end

function decision = slicePam4(sample)
decision = 3 * ones(size(sample));
decision(sample < 2) = 1;
decision(sample < 0) = -1;
decision(sample < -2) = -3;
end

function levelCenters = calculateKnownLevelCenters(output, known)
levels = [-3 -1 1 3];
levelCenters = zeros(1, numel(levels));
for levelIndex = 1:numel(levels)
    selected = output(known == levels(levelIndex));
    assert(~isempty(selected), 'A PAM4 level is absent from the DD validation segment.');
    levelCenters(levelIndex) = mean(selected);
end
end

function plotMuScan(metrics, selectedIndex, outputPath)
mu = [metrics.Mu];
tailMse = [metrics.SupervisedTailMse];
coefficientSpan = [metrics.SupervisedCoefficientSpan];
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
yyaxis left;
loglog(mu, tailMse, 'o-', 'LineWidth', 1.3, 'MarkerSize', 6);
ylabel('Supervised tail MSE');
yyaxis right;
semilogx(mu, coefficientSpan, 's-', 'LineWidth', 1.3, 'MarkerSize', 6);
ylabel('Tail coefficient span');
hold on;
xline(mu(selectedIndex), 'k--', 'Selected \mu', 'LineWidth', 1.2);
grid on;
xlabel('LMS step size \mu');
title('Supervised-only CDR FFE step-size scan');
exportgraphics(fig, outputPath, 'Resolution', 180);
close(fig);
end

function plotCoefficientTrace(coefficientTrace, trainingBlocks, outputPath)
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
plot(0:size(coefficientTrace, 1) - 1, coefficientTrace, 'LineWidth', 1.2);
hold on;
xline(trainingBlocks, 'k--', 'Supervised to DD', 'LineWidth', 1.2);
grid on;
xlabel('Block update');
ylabel('FFE coefficient');
title('Six-tap CDR FFE coefficient convergence');
legend('pre2', 'pre1', 'main', 'post1', 'post2', 'post3', 'Location', 'best');
exportgraphics(fig, outputPath, 'Resolution', 180);
close(fig);
end

function plotMseTrace(truthMse, updateMse, trainingBlocks, outputPath)
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
semilogy(1:numel(truthMse), truthMse, 'LineWidth', 1.2);
hold on;
semilogy(1:numel(updateMse), updateMse, 'LineWidth', 1.2);
xline(trainingBlocks, 'k--', 'Supervised to DD', 'LineWidth', 1.2);
grid on;
xlabel('Block update');
ylabel('Block mean-square error');
title('CDR FFE supervised and decision-directed MSE');
legend('Truth-referenced MSE', 'Update-error MSE', 'Location', 'best');
exportgraphics(fig, outputPath, 'Resolution', 180);
close(fig);
end

function plotBeforeAfter(beforeOutput, afterOutput, knownTarget, trainingBlocks, blockSize, outputPath)
ddSampleIndex = trainingBlocks * blockSize + 1:numel(knownTarget);
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 720]);
tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
nexttile;
histogram(beforeOutput(ddSampleIndex), 100, 'Normalization', 'probability');
grid on;
xlabel('Scaled main-only ADC sample');
ylabel('Probability');
title('Before adaptation');
nexttile;
histogram(afterOutput(ddSampleIndex), 100, 'Normalization', 'probability');
grid on;
xlabel('FFE output');
ylabel('Probability');
title('After adaptation during DD validation');
exportgraphics(fig, outputPath, 'Resolution', 180);
close(fig);
end
