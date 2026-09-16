function result = test_cdr_top_ctle_waveform_mmpd_v1
% Weighted all-transition PAM4 MMPD experiment, version 1.

thisFile = mfilename('fullpath');
repoRoot = fileparts(fileparts(fileparts(thisFile)));
addpath(fullfile(repoRoot, 'src', 'CDR'));

csvPath = fullfile(repoRoot, 'data', 'ADC', 'TI_ADC', 'ctle_out.csv');
resultDir = fullfile(repoRoot, 'results', 'CDR');
if ~exist(resultDir, 'dir'), mkdir(resultDir); end

samplesPerUI = 128;
blockSize = 64;
numBlocks = 50;
numUi = blockSize * numBlocks;
startUi = 1;
fixture = readmatrix(csvPath);
voltage = fixture(:, 2).';
assert(numel(voltage) >= (startUi + numUi + 1) * samplesPerUI, ...
    'CTLE fixture is too short for weighted-MMPD v1.');

% Calibrate PAM4 levels at the maximum-power data phase.
calibrationUi = 0:numUi - 1;
phasePower = zeros(1, samplesPerUI);
for phase = 0:samplesPerUI - 1
    index = calibrationUi * samplesPerUI + phase + 1;
    phasePower(phase + 1) = mean(voltage(index).^2);
end
[~, powerIndex] = max(phasePower);
referenceDataPhase = powerIndex - 1;
calibrationIndex = calibrationUi * samplesPerUI + referenceDataPhase + 1;
levelCenter = estimatePam4Centers(voltage(calibrationIndex));
threshold = (levelCenter(1:3) + levelCenter(2:4)) / 2;

% The loop voter is linear, so its S-curve is the unconditional mean over
% all UI, including zero decisions. Conditional mean is retained only for
% diagnosis of decision polarity when a transition is valid.
[loopMean, conditionalMean, validCount, transition] = measureCharacteristic( ...
    voltage, threshold, levelCenter, samplesPerUI, startUi, numUi);
reconstructedLoopMean = squeeze(sum(sum(transition.LoopMean, 1), 2)).';
assert(max(abs(reconstructedLoopMean - loopMean)) < 1e-12, ...
    'Per-transition S-curves do not reconstruct the aggregate S-curve.');
transitionGroup = combineSymmetricTransitionGroups(transition, numUi);
reconstructedGroupMean = sum(transitionGroup.LoopMean, 1);
assert(max(abs(reconstructedGroupMean - loopMean)) < 1e-12, ...
    'Symmetric-group S-curves do not reconstruct the aggregate S-curve.');
baselineGroupWeight = [1 1 2 2];
assert(max(abs(baselineGroupWeight * transitionGroup.UnitLoopMean - ...
    loopMean)) < 1e-12, ...
    'Unit-weight group curves do not reconstruct the baseline S-curve.');
[weightSearch, selectedGroupWeight] = searchSymmetricGroupWeights( ...
    transitionGroup.UnitLoopMean, referenceDataPhase, samplesPerUI);
optimizedLoopMean = selectedGroupWeight * transitionGroup.UnitLoopMean;
optimizedMetric = characterizeStableZeros(optimizedLoopMean, ...
    referenceDataPhase, samplesPerUI);
optimizedLockPhase = optimizedMetric.LockPhase;
lockPhase = selectLockPhase(loopMean, validCount, referenceDataPhase, ...
    samplesPerUI, numUi);

% Search loop gains and starting phases. MaxDeltaCode=Inf is explicit for
% this experiment; linear voter output contains weighted signed sums.
kpCandidate = [0.002 0.004 0.008 0.016 0.032 0.064 0.128 0.256 0.5];
kiCandidate = [0 0.00001 0.00005 0.0001 0.0002 0.0005 0.001 0.002];
polarityCandidate = [1 -1];
offsetCandidate = [0 1:63 -1:-1:-64];

scan = struct('Kp', {}, 'Ki', {}, 'Polarity', {}, 'InitialPhase', {}, ...
    'InitialDistance', {}, 'MeanError', {}, 'PhaseSpan', {}, ...
    'Drift', {}, 'Score', {}, 'Trace', {});
scanIndex = 0;
for polarity = polarityCandidate
    for initialOffset = offsetCandidate
        initialPhase = mod(optimizedLockPhase + initialOffset, samplesPerUI);
        initialDistance = abs(wrapSampleError( ...
            initialPhase - optimizedLockPhase, samplesPerUI));
        for kp = kpCandidate
            for ki = kiCandidate
                trace = runClosedLoop(voltage, threshold, levelCenter, ...
                    samplesPerUI, startUi, blockSize, numBlocks, ...
                    optimizedLockPhase, ...
                    initialPhase, kp, ki, polarity, selectedGroupWeight);
                steady = numBlocks - 19:numBlocks;
                meanError = mean(trace.PhaseErrorSample(steady));
                phaseSpan = max(trace.SampleIndexForBlock(steady)) - ...
                    min(trace.SampleIndexForBlock(steady));
                drift = abs(mean(diff(trace.SampleIndexForBlock(steady))));
                scanIndex = scanIndex + 1;
                scan(scanIndex).Kp = kp;
                scan(scanIndex).Ki = ki;
                scan(scanIndex).Polarity = polarity;
                scan(scanIndex).InitialPhase = initialPhase;
                scan(scanIndex).InitialDistance = initialDistance;
                scan(scanIndex).MeanError = meanError;
                scan(scanIndex).PhaseSpan = phaseSpan;
                scan(scanIndex).Drift = drift;
                scan(scanIndex).Score = abs(meanError) + ...
                    0.25 * phaseSpan + 8 * drift;
                scan(scanIndex).Trace = trace;
            end
        end
    end
end

feasible = abs([scan.MeanError]) <= 3 & [scan.PhaseSpan] <= 8 & ...
    [scan.Drift] <= 0.25;
assert(any(feasible), 'No weighted-MMPD v1 candidate converged.');
offsetAxis = -samplesPerUI / 2:samplesPerUI / 2 - 1;
offsetPass = false(size(offsetAxis));
for offsetIndex = 1:numel(offsetAxis)
    targetInitialPhase = mod(optimizedLockPhase + ...
        offsetAxis(offsetIndex), samplesPerUI);
    phaseMatch = abs(wrapSampleError([scan.InitialPhase] - ...
        targetInitialPhase, samplesPerUI)) < 1e-9;
    offsetPass(offsetIndex) = any(feasible & phaseMatch);
end
edge = diff([false offsetPass false]);
rangeStart = find(edge == 1);
rangeStop = find(edge == -1) - 1;
zeroIndex = find(offsetAxis == 0, 1);
selectedRange = find(rangeStart <= zeroIndex & rangeStop >= zeroIndex, 1);
assert(~isempty(selectedRange), ...
    'No continuous acquisition interval contains the target lock phase.');
continuousOffsetRange = [offsetAxis(rangeStart(selectedRange)) ...
    offsetAxis(rangeStop(selectedRange))];
continuousInitialPhaseRange = mod(optimizedLockPhase + ...
    continuousOffsetRange, samplesPerUI);
maxDistance = max([scan(feasible).InitialDistance]);
farthest = feasible & [scan.InitialDistance] == maxDistance;
score = [scan.Score];
score(~farthest) = Inf;
[~, bestIndex] = min(score);
best = scan(bestIndex);
trace = best.Trace;

assert(any(trace.PhaseError > 0) && any(trace.PhaseError < 0), ...
    'Linear voter output did not reverse around the selected lock point.');
assert(all(isfinite(trace.DeltaCode)), 'Loop produced a nonfinite delta code.');

fprintf(['Weighted MMPD v1: power phase=%d, lock=%.2f, initial=%.1f ' ...
    '(distance=%.1f), Kp=%.6g, Ki=%.6g, polarity=%+d, ' ...
    'mean=%.3f, span=%.3f, drift=%.3f, valid=%d, cadence=%d UI/block.\n'], ...
    referenceDataPhase, optimizedLockPhase, best.InitialPhase, ...
    best.InitialDistance, best.Kp, best.Ki, best.Polarity, ...
    best.MeanError, best.PhaseSpan, best.Drift, sum(trace.ValidCount), blockSize);
fprintf(['Continuous acquisition interval: offset=[%+d,%+d] samples, ' ...
    'requested phase=[%.2f,%.2f], width=%d samples (%.4f UI).\n'], ...
    continuousOffsetRange, continuousInitialPhaseRange, ...
    diff(continuousOffsetRange), diff(continuousOffsetRange) / samplesPerUI);

figurePath = fullfile(resultDir, 'cdr_top_ctle_convergence_mmpd_v1.png');
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1150 1050]);
tiled = tiledlayout(fig, 5, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tiled, 'Weighted all-transition PAM4 MMPD v1');

phaseAxis = 0:samplesPerUI - 1;
nexttile;
plot(phaseAxis, loopMean, 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
hold on;
plot(phaseAxis, optimizedLoopMean, 'b-', 'LineWidth', 1.2);
hold on; yline(0, 'k--');
xline(referenceDataPhase, 'r:', 'LineWidth', 1.2);
xline(optimizedLockPhase, 'm--', 'LineWidth', 1.2);
grid on; xlim([0 samplesPerUI - 1]);
ylabel('mean/UI'); title('Baseline and optimized unconditional S-curves');
legend('baseline [1 1 2 2]', 'optimized [2 1 2 1]', 'zero', ...
    'power phase', 'optimized lock', 'Location', 'best');

nexttile;
yyaxis left; plot(phaseAxis, conditionalMean, 'b-', 'LineWidth', 1.0);
ylabel('mean/valid');
yyaxis right; plot(phaseAxis, validCount / numUi, 'g-', 'LineWidth', 1.0);
ylabel('valid density'); grid on; xlim([0 samplesPerUI - 1]);
title('Conditional decision and transition density');

blockAxis = 1:numBlocks;
nexttile;
plot(blockAxis, trace.SampleIndexForBlock, 'b-o', ...
    'LineWidth', 1.2, 'MarkerSize', 3);
hold on; yline(optimizedLockPhase, 'm--', 'LineWidth', 1.2);
grid on; ylabel('phase (sample)'); title('PI phase convergence');

nexttile;
stairs(blockAxis, trace.PhaseErrorSample, 'LineWidth', 1.2);
hold on; yline(0, 'k--'); grid on;
ylabel('error (sample)'); title('Wrapped phase error');

nexttile;
yyaxis left; stairs(blockAxis, trace.PhaseError, 'LineWidth', 1.2);
ylabel('linear vote');
yyaxis right; stairs(blockAxis, trace.DeltaCode, '--', 'LineWidth', 1.2);
ylabel('\Delta PI code'); grid on;
xlabel(sprintf('%d-UI block index', blockSize));
title(sprintf('Kp=%.6g, Ki=%.6g, polarity=%+d, unlimited delta', ...
    best.Kp, best.Ki, best.Polarity));

exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);

transitionFigurePath = fullfile(resultDir, ...
    'cdr_top_ctle_mmpd_v1_transition_scurves.png');
plotTransitionCharacteristics(transition, phaseAxis, numUi, ...
    referenceDataPhase, lockPhase, transitionFigurePath);

groupFigurePath = fullfile(resultDir, ...
    'cdr_top_ctle_mmpd_v1_symmetric_group_scurves.png');
plotSymmetricGroupCharacteristics(transitionGroup, phaseAxis, numUi, ...
    referenceDataPhase, lockPhase, groupFigurePath);

weightFigurePath = fullfile(resultDir, ...
    'cdr_top_ctle_mmpd_v1_group_weight_search.png');
plotGroupWeightSearch(loopMean, optimizedLoopMean, phaseAxis, ...
    referenceDataPhase, optimizedMetric, selectedGroupWeight, ...
    weightFigurePath);

result = struct();
result.WaveformCsv = csvPath;
result.ReferenceDataPhase = referenceDataPhase;
result.LockPhase = lockPhase;
result.LevelCenter = levelCenter;
result.Threshold = threshold;
result.LoopMean = loopMean;
result.ConditionalMean = conditionalMean;
result.ValidCount = validCount;
result.Transition = transition;
result.TransitionGroup = transitionGroup;
result.GroupWeightSearch = weightSearch;
result.SelectedGroupWeight = selectedGroupWeight;
result.OptimizedLoopMean = optimizedLoopMean;
result.OptimizedMetric = optimizedMetric;
result.OptimizedLockPhase = optimizedLockPhase;
result.Kp = best.Kp;
result.Ki = best.Ki;
result.Polarity = best.Polarity;
result.InitialPhase = best.InitialPhase;
result.InitialDistance = best.InitialDistance;
result.ContinuousOffsetRange = continuousOffsetRange;
result.ContinuousInitialPhaseRange = continuousInitialPhaseRange;
result.OffsetAxis = offsetAxis;
result.OffsetPass = offsetPass;
result.Scan = rmfield(scan, 'Trace');
result.Trace = trace;
result.FigurePath = figurePath;
result.TransitionFigurePath = transitionFigurePath;
result.GroupFigurePath = groupFigurePath;
result.WeightFigurePath = weightFigurePath;
fprintf('test_cdr_top_ctle_waveform_mmpd_v1 passed.\n');
end

function trace = runClosedLoop(voltage, threshold, center, samplesPerUI, ...
        startUi, blockSize, numBlocks, lockPhase, initialPhase, Kp, Ki, ...
        polarity, groupWeight)
pd = cdr_pd('pam4', polarity);
voter = cdr_voter('linear', blockSize, 8);
loopFilter = cdr_loop(Kp, Ki, -4, 4, Inf);
piModel = cdr_pi(8, samplesPerUI);
piModel.resetNonideal();
piModel.setCode(round(initialPhase * piModel.NumCode / samplesPerUI));
localIndex = piModel.getLocalIndex();

previousIndex = (startUi - 1) * samplesPerUI + round(initialPhase) + 1;
[previousSymbol, previousError] = slicePam4WithError( ...
    voltage(previousIndex), threshold, center);

samplePhase = zeros(1, numBlocks);
phaseError = zeros(1, numBlocks);
deltaCode = zeros(1, numBlocks);
validCount = zeros(1, numBlocks);
for block = 1:numBlocks
    samplePhase(block) = localIndex;
    ui = startUi + (block - 1) * blockSize + (0:blockSize - 1);
    index = ui * samplesPerUI + round(localIndex) + 1;
    [dataCurr, errorCurr] = slicePam4WithError(voltage(index), threshold, center);
    dataPrev = [previousSymbol dataCurr(1:end - 1)];
    errorPrev = [previousError errorCurr(1:end - 1)];
    [decision, valid] = pd.mmpdFast(dataPrev, errorPrev, dataCurr, errorCurr);
    decision = applySymmetricGroupWeights(decision, valid, dataPrev, ...
        dataCurr, groupWeight);
    phaseError(block) = double(voter.voteFast(decision));
    deltaCode(block) = loopFilter.updateFast(phaseError(block));
    localIndex = piModel.updateFast(deltaCode(block));
    validCount(block) = sum(valid);
    previousSymbol = dataCurr(end);
    previousError = errorCurr(end);
end
trace = struct();
trace.SampleIndexForBlock = samplePhase;
trace.PhaseErrorSample = wrapSampleError(samplePhase - lockPhase, samplesPerUI);
trace.PhaseError = phaseError;
trace.DeltaCode = deltaCode;
trace.ValidCount = validCount;
end

function decision = applySymmetricGroupWeights(decision, valid, dataPrev, ...
        dataCurr, groupWeight)
groupIndex = zeros(size(dataPrev));
groupIndex((dataPrev == 0 & dataCurr == 1) | ...
    (dataPrev == 1 & dataCurr == 0) | ...
    (dataPrev == 2 & dataCurr == 3) | ...
    (dataPrev == 3 & dataCurr == 2)) = 1;
groupIndex((dataPrev == 0 & dataCurr == 2) | ...
    (dataPrev == 2 & dataCurr == 0) | ...
    (dataPrev == 1 & dataCurr == 3) | ...
    (dataPrev == 3 & dataCurr == 1)) = 2;
groupIndex((dataPrev == 0 & dataCurr == 3) | ...
    (dataPrev == 3 & dataCurr == 0)) = 3;
groupIndex((dataPrev == 1 & dataCurr == 2) | ...
    (dataPrev == 2 & dataCurr == 1)) = 4;
weightedDecision = zeros(size(decision), 'int8');
direction = int8(sign(double(decision)));
for group = 1:4
    mask = valid & groupIndex == group;
    weightedDecision(mask) = direction(mask) * int8(groupWeight(group));
end
decision = weightedDecision;
end

function [loopMean, conditionalMean, validCount, transition] = measureCharacteristic( ...
        voltage, threshold, center, samplesPerUI, startUi, numUi)
pd = cdr_pd('pam4', 1);
loopMean = zeros(1, samplesPerUI);
conditionalMean = zeros(1, samplesPerUI);
validCount = zeros(1, samplesPerUI);
transitionLoopMean = zeros(4, 4, samplesPerUI);
transitionConditionalMean = zeros(4, 4, samplesPerUI);
transitionValidCount = zeros(4, 4, samplesPerUI);
ui = startUi + (0:numUi - 1);
for phase = 0:samplesPerUI - 1
    index = ui * samplesPerUI + phase + 1;
    previousIndex = (startUi - 1) * samplesPerUI + phase + 1;
    [dataCurr, errorCurr] = slicePam4WithError(voltage(index), threshold, center);
    [previousSymbol, previousError] = slicePam4WithError( ...
        voltage(previousIndex), threshold, center);
    dataPrev = [previousSymbol dataCurr(1:end - 1)];
    errorPrev = [previousError errorCurr(1:end - 1)];
    [decision, valid] = pd.mmpdFast(dataPrev, errorPrev, dataCurr, errorCurr);
    decisionSum = sum(double(decision));
    validCount(phase + 1) = sum(valid);
    loopMean(phase + 1) = decisionSum / numUi;
    conditionalMean(phase + 1) = decisionSum / max(validCount(phase + 1), 1);
    for dataPrevValue = 0:3
        for dataCurrValue = 0:3
            if dataPrevValue == dataCurrValue, continue; end
            transitionMask = valid & dataPrev == dataPrevValue & ...
                dataCurr == dataCurrValue;
            count = sum(transitionMask);
            transitionValidCount(dataPrevValue + 1, dataCurrValue + 1, ...
                phase + 1) = count;
            transitionDecisionSum = sum(double(decision(transitionMask)));
            transitionLoopMean(dataPrevValue + 1, dataCurrValue + 1, ...
                phase + 1) = transitionDecisionSum / numUi;
            transitionConditionalMean(dataPrevValue + 1, dataCurrValue + 1, ...
                phase + 1) = transitionDecisionSum / max(count, 1);
        end
    end
end
transition = struct();
transition.LoopMean = transitionLoopMean;
transition.ConditionalMean = transitionConditionalMean;
transition.ValidCount = transitionValidCount;
transition.Weight = ones(4, 4);
transition.Weight(1, 4) = 2;
transition.Weight(4, 1) = 2;
transition.Weight(2, 3) = 2;
transition.Weight(3, 2) = 2;
end

function plotTransitionCharacteristics(transition, phaseAxis, numUi, ...
        referenceDataPhase, lockPhase, figurePath)
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [50 50 1500 1050]);
tiled = tiledlayout(fig, 4, 3, 'TileSpacing', 'compact', ...
    'Padding', 'compact');
title(tiled, ['Weighted MMPD v1: per-directed-transition ' ...
    'conditional S-curves']);
transitionIndex = 0;
for dataPrevValue = 0:3
    for dataCurrValue = 0:3
        if dataPrevValue == dataCurrValue, continue; end
        transitionIndex = transitionIndex + 1;
        nexttile(transitionIndex);
        conditionalMean = squeeze(transition.ConditionalMean( ...
            dataPrevValue + 1, dataCurrValue + 1, :)).';
        density = squeeze(transition.ValidCount( ...
            dataPrevValue + 1, dataCurrValue + 1, :)).' / numUi;
        yyaxis left;
        plot(phaseAxis, conditionalMean, 'b-', 'LineWidth', 1.0);
        hold on;
        yline(0, 'k--');
        xline(referenceDataPhase, 'r:', 'LineWidth', 0.9);
        xline(lockPhase, 'm--', 'LineWidth', 0.9);
        ylabel('mean/valid');
        yyaxis right;
        plot(phaseAxis, density, 'g-', 'LineWidth', 0.9);
        ylabel('density');
        grid on;
        xlim([phaseAxis(1) phaseAxis(end)]);
        title(sprintf('%d -> %d, weight=%d', dataPrevValue, ...
            dataCurrValue, transition.Weight(dataPrevValue + 1, ...
            dataCurrValue + 1)));
        if transitionIndex > 9, xlabel('phase (sample)'); end
    end
end
exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);
end

function group = combineSymmetricTransitionGroups(transition, numUi)
% Each row contains directed-transition indices encoded as 4*prev+curr.
groupCode = {
    [1 4 11 14], ... % 0<->1 and 2<->3
    [2 8 7 13], ... % 0<->2 and 1<->3
    [3 12], ...      % 0<->3
    [6 9]};          % 1<->2
groupName = {
    'G1 adjacent outer: 0<->1, 2<->3', ...
    'G2 skip-one: 0<->2, 1<->3', ...
    'G3 outer symmetric: 0<->3', ...
    'G4 inner symmetric: 1<->2'};
numGroup = numel(groupCode);
numPhase = size(transition.LoopMean, 3);
loopMean = zeros(numGroup, numPhase);
unitLoopMean = zeros(numGroup, numPhase);
conditionalMean = zeros(numGroup, numPhase);
validCount = zeros(numGroup, numPhase);
for groupIndex = 1:numGroup
    for code = groupCode{groupIndex}
        dataPrevValue = floor(code / 4);
        dataCurrValue = mod(code, 4);
        loopContribution = squeeze(transition.LoopMean( ...
            dataPrevValue + 1, dataCurrValue + 1, :)).';
        count = squeeze(transition.ValidCount( ...
            dataPrevValue + 1, dataCurrValue + 1, :)).';
        loopMean(groupIndex, :) = loopMean(groupIndex, :) + ...
            loopContribution;
        unitLoopMean(groupIndex, :) = unitLoopMean(groupIndex, :) + ...
            loopContribution / transition.Weight(dataPrevValue + 1, ...
            dataCurrValue + 1);
        validCount(groupIndex, :) = validCount(groupIndex, :) + count;
    end
    conditionalMean(groupIndex, :) = loopMean(groupIndex, :) * numUi ./ ...
        max(validCount(groupIndex, :), 1);
end
group = struct();
group.Name = groupName;
group.Code = groupCode;
group.LoopMean = loopMean;
group.UnitLoopMean = unitLoopMean;
group.ValidCount = validCount;
group.ConditionalMean = conditionalMean;
end

function plotSymmetricGroupCharacteristics(group, phaseAxis, numUi, ...
        referenceDataPhase, lockPhase, figurePath)
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [80 80 1450 850]);
tiled = tiledlayout(fig, 2, 2, 'TileSpacing', 'compact', ...
    'Padding', 'compact');
title(tiled, 'Weighted MMPD v1: four symmetric transition groups');
for groupIndex = 1:4
    nexttile(groupIndex);
    yyaxis left;
    plot(phaseAxis, group.ConditionalMean(groupIndex, :), 'b-', ...
        'LineWidth', 1.2);
    hold on;
    plot(phaseAxis, group.LoopMean(groupIndex, :), 'c--', ...
        'LineWidth', 1.0);
    yline(0, 'k--');
    xline(referenceDataPhase, 'r:', 'LineWidth', 1.0);
    xline(lockPhase, 'm--', 'LineWidth', 1.0);
    ylabel('decision mean');
    yyaxis right;
    plot(phaseAxis, group.ValidCount(groupIndex, :) / numUi, ...
        'g-', 'LineWidth', 1.0);
    ylabel('valid density');
    grid on;
    xlim([phaseAxis(1) phaseAxis(end)]);
    xlabel('phase (sample)');
    title(group.Name{groupIndex});
    legend('conditional', 'unconditional', 'zero', 'power phase', ...
        'selected lock', 'density', 'Location', 'best');
end
exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);
end

function [search, selectedWeight] = searchSymmetricGroupWeights( ...
        unitLoopMean, referencePhase, samplesPerUI)
search = struct('Weight', {}, 'LockPhase', {}, 'LockDistance', {}, ...
    'CaptureWidth', {}, 'StableZeroCount', {}, 'OtherStableZeroCount', {}, ...
    'LockSlope', {}, 'Score', {});
searchIndex = 0;
for w1 = 0:4
    for w2 = 0:4
        for w3 = 0:4
            for w4 = 0:4
                weight = [w1 w2 w3 w4];
                if ~any(weight), continue; end
                divisor = weight(find(weight > 0, 1));
                for value = weight(weight > 0)
                    divisor = gcd(divisor, value);
                end
                if divisor > 1, continue; end
                normalizedWeight = weight / sum(weight);
                curve = normalizedWeight * unitLoopMean;
                metric = characterizeStableZeros(curve, referencePhase, ...
                    samplesPerUI);
                if ~isfinite(metric.LockPhase), continue; end
                searchIndex = searchIndex + 1;
                search(searchIndex).Weight = weight;
                search(searchIndex).LockPhase = metric.LockPhase;
                search(searchIndex).LockDistance = metric.LockDistance;
                search(searchIndex).CaptureWidth = metric.CaptureWidth;
                search(searchIndex).StableZeroCount = ...
                    metric.StableZeroCount;
                search(searchIndex).OtherStableZeroCount = ...
                    metric.OtherStableZeroCount;
                search(searchIndex).LockSlope = metric.LockSlope;
                search(searchIndex).Score = 20 * metric.LockDistance + ...
                    6 * metric.OtherStableZeroCount - metric.CaptureWidth - ...
                    20 * abs(metric.LockSlope);
            end
        end
    end
end
assert(~isempty(search), 'No group-weight candidate produced a stable zero.');
score = [search.Score];
[~, selectedIndex] = min(score);
selectedWeight = search(selectedIndex).Weight;
fprintf(['MMPD group-weight search: weight=[%d %d %d %d], lock=%.2f, ' ...
    'distance=%.2f, basin=%.2f samples, stable zeros=%d, slope=%+.5g.\n'], ...
    selectedWeight, search(selectedIndex).LockPhase, ...
    search(selectedIndex).LockDistance, ...
    search(selectedIndex).CaptureWidth, ...
    search(selectedIndex).StableZeroCount, ...
    search(selectedIndex).LockSlope);
end

function metric = characterizeStableZeros(curve, referencePhase, samplesPerUI)
smoothCurve = circularMovingMean(curve,  nineSampleWindow(samplesPerUI));
stablePhase = [];
stableSlope = [];
unstablePhase = [];
curveSign = sign(smoothCurve);
nonzeroIndex = find(curveSign ~= 0);
if isempty(nonzeroIndex)
    metric = struct('SmoothedCurve', smoothCurve, 'StablePhase', [], ...
        'UnstablePhase', [], 'LockPhase', NaN, 'LockDistance', Inf, ...
        'CaptureWidth', 0, 'StableZeroCount', 0, ...
        'OtherStableZeroCount', Inf, 'LockSlope', 0);
    return;
end
for index = find(curveSign == 0)
    previous = nonzeroIndex(nonzeroIndex < index);
    if isempty(previous), previous = nonzeroIndex(end); end
    curveSign(index) = curveSign(previous(end));
end
for index = 1:samplesPerUI
    nextIndex = mod(index, samplesPerUI) + 1;
    first = smoothCurve(index);
    second = smoothCurve(nextIndex);
    if curveSign(index) == curveSign(nextIndex), continue; end
    denominator = abs(first) + abs(second);
    if denominator == 0
        fraction = 0.5;
    else
        fraction = abs(first) / denominator;
    end
    phase = mod(index - 1 + fraction, samplesPerUI);
    slope = second - first;
    if slope < 0
        stablePhase(end + 1) = phase; %#ok<AGROW>
        stableSlope(end + 1) = slope; %#ok<AGROW>
    else
        unstablePhase(end + 1) = phase; %#ok<AGROW>
    end
end
metric = struct('SmoothedCurve', smoothCurve, 'StablePhase', stablePhase, ...
    'UnstablePhase', unstablePhase, 'LockPhase', NaN, 'LockDistance', Inf, ...
    'CaptureWidth', 0, 'StableZeroCount', numel(stablePhase), ...
    'OtherStableZeroCount', Inf, 'LockSlope', 0);
if isempty(stablePhase), return; end
distance = abs(wrapSampleError(stablePhase - referencePhase, samplesPerUI));
[metric.LockDistance, selectedIndex] = min(distance);
metric.LockPhase = stablePhase(selectedIndex);
metric.LockSlope = stableSlope(selectedIndex);
metric.OtherStableZeroCount = numel(stablePhase) - 1;
if isempty(unstablePhase)
    metric.CaptureWidth = samplesPerUI;
    return;
end
clockwise = mod(unstablePhase - metric.LockPhase, samplesPerUI);
counterclockwise = mod(metric.LockPhase - unstablePhase, samplesPerUI);
clockwise(clockwise == 0) = samplesPerUI;
counterclockwise(counterclockwise == 0) = samplesPerUI;
metric.CaptureWidth = min(clockwise) + min(counterclockwise);
end

function window = nineSampleWindow(samplesPerUI)
window = min(9, samplesPerUI);
if mod(window, 2) == 0, window = window - 1; end
end

function value = circularMovingMean(value, window)
halfWindow = floor(window / 2);
extended = [value(end - halfWindow + 1:end) value ...
    value(1:halfWindow)];
filtered = movmean(extended, window, 'Endpoints', 'discard');
value = filtered(1:numel(value));
end

function plotGroupWeightSearch(baseline, optimized, phaseAxis, ...
        referencePhase, optimizedMetric, selectedWeight, figurePath)
fig = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100 100 1250 650]);
plot(phaseAxis, circularMovingMean(baseline, 9), 'Color', [0.5 0.5 0.5], ...
    'LineWidth', 1.1);
hold on;
plot(phaseAxis, optimizedMetric.SmoothedCurve, 'b-', 'LineWidth', 1.5);
yline(0, 'k--');
xline(referencePhase, 'r:', 'LineWidth', 1.3);
for phase = optimizedMetric.StablePhase
    xline(phase, 'm--', 'LineWidth', 0.8);
end
for phase = optimizedMetric.UnstablePhase
    xline(phase, 'Color', [0.85 0.55 0], 'LineStyle', ':', ...
        'LineWidth', 0.8);
end
grid on;
xlim([phaseAxis(1) phaseAxis(end)]);
xlabel('phase (sample)');
ylabel('smoothed unconditional mean/UI');
title(sprintf(['Group-weight search: [G1 G2 G3 G4]=[%d %d %d %d], ' ...
    'target lock %.2f, basin %.2f samples'], selectedWeight, ...
    optimizedMetric.LockPhase, optimizedMetric.CaptureWidth));
legend('baseline [1 1 2 2]', 'optimized', 'zero', 'power phase', ...
    'stable zeros', 'unstable zeros', 'Location', 'best');
exportgraphics(fig, figurePath, 'Resolution', 200);
close(fig);
end

function lockPhase = selectLockPhase(loopMean, validCount, referencePhase, samplesPerUI, numUi)
candidate = 0:samplesPerUI - 1;
distance = abs(wrapSampleError(candidate - referencePhase, samplesPerUI));
smoothMean = movmean(loopMean, 5, 'Endpoints', 'shrink');
slope = gradient(smoothMean);
mask = distance <= samplesPerUI / 4 & validCount >= 0.05 * numUi & slope < 0;
score = abs(smoothMean) + 0.002 * distance - 0.02 * abs(slope);
score(~mask) = Inf;
[~, index] = min(score);
assert(isfinite(score(index)), 'No stable weighted-MMPD lock candidate found.');
lockPhase = index - 1;
end

function [symbol, errorBit] = slicePam4WithError(sample, threshold, center)
symbol = double(sample > threshold(1)) + double(sample > threshold(2)) + ...
    double(sample > threshold(3));
symbolCenter = center(symbol + 1);
negative = symbol <= 1;
errorBit = (negative & sample > symbolCenter) | (~negative & sample < symbolCenter);
end

function center = estimatePam4Centers(sample)
center = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    [~, cluster] = min(abs(sample(:) - center), [], 2);
    updated = center;
    for level = 1:4
        values = sample(cluster == level);
        assert(~isempty(values), 'PAM4 clustering produced an empty level.');
        updated(level) = mean(values);
    end
    updated = sort(updated);
    if max(abs(updated - center)) < 1e-12, center = updated; break; end
    center = updated;
end
end

function value = wrapSampleError(value, samplesPerUI)
value = mod(value + samplesPerUI / 2, samplesPerUI) - samplesPerUI / 2;
end
