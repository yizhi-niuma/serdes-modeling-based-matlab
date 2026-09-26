function test_build_ppm_eye_set
%TEST_BUILD_PPM_EYE_SET Targeted frequency-offset eye-set tests.

originalPath = path;
pathCleanup = onCleanup(@() path(originalPath));
thisFile = mfilename('fullpath');
repoRoot = fileparts(fileparts(fileparts(thisFile)));
suiteRoot = fullfile(repoRoot, 'validation', 'CDR', ...
    'test_cdr_three_loop_wi_ppm');
addpath(suiteRoot, '-begin');
setup_cdr_three_loop_wi_ppm_paths();

checkDriftAwareWindowsMatchDirectCalls();
checkZeroDriftReducesToSiblingWindows();
checkAddressTraceConsistencyGuard();
checkMarkerWrapSafety();
checkNaNAnchorAndTruncation();
checkInvalidInputsRejected();
checkMetaCompleteness();
checkVariableAnchorCounts();
checkAnchorLabels();

fprintf('test_build_ppm_eye_set passed 9 / 9 checks.\n');
end

function checkDriftAwareWindowsMatchDirectCalls()
info = fixtureInfo(36, 1.75, {'early', 'middle', 'late'});
anchorBlocks = [4 13 25];
requested = 48;
wave = fixtureWaveform(info);
[eyes, setMeta] = build_ppm_eye_set(wave, info, anchorBlocks, requested);
blockStartUi = reconstructedBlockStarts(info);
expectedStarts = [blockStartUi(anchorBlocks), ...
    max(blockStartUi(1), blockStartUi(end) + info.AdcBlockUi - requested)];
coefficientRows = [anchorBlocks, info.NumBlocks];

assert(all([eyes.Valid]));
for eyeIndex = 1:numel(eyes)
    expectedCoefficients = info.FfeCoeffTrace(coefficientRows(eyeIndex), :);
    directEye = build_cdr_ffe_eye(wave, expectedStarts(eyeIndex), ...
        requested, info.SamplesPerUi, expectedCoefficients, ...
        info.PreTapCount, info.AdcBits, info.AdcRange);
    assert(eyes(eyeIndex).StartUi == expectedStarts(eyeIndex));
    assert(isequal(eyes(eyeIndex).OutputCodeGrid, directEye.OutputCodeGrid));
    assert(isequal(eyes(eyeIndex).Coefficients, expectedCoefficients));
    assert(isequal(setMeta.Coefficients{eyeIndex}, expectedCoefficients));
end
assert(numel(unique(info.FfeCoeffTrace(coefficientRows, 1))) == ...
    numel(coefficientRows));
end

function checkZeroDriftReducesToSiblingWindows()
info = fixtureInfo(18, 0, {'first', 'second'});
anchorBlocks = [3 11];
requested = 32;
wave = fixtureWaveform(info);
[eyes, ~] = build_ppm_eye_set(wave, info, anchorBlocks, requested);
blockStartUi = reconstructedBlockStarts(info);
siblingStartUi = info.BaseUi + (0:(info.NumBlocks - 1)) * ...
    info.AdcBlockUi + info.UiSlipTrace;
expectedFinalStart = max(siblingStartUi(1), ...
    siblingStartUi(end) + info.AdcBlockUi - requested);

assert(all(info.DriftSampleTrace == 0));
assert(isequal(blockStartUi, siblingStartUi));
assert(isequal([eyes(1:2).StartUi], siblingStartUi(anchorBlocks)));
assert(eyes(end).StartUi == expectedFinalStart);
end

function checkAddressTraceConsistencyGuard()
info = fixtureInfo(12, 1.25, {'anchor'});
wave = fixtureWaveform(info);
perturbedBlock = 6;
info.DriftSampleTrace(perturbedBlock) = ...
    info.DriftSampleTrace(perturbedBlock) + 1;
caught = false;
try
    build_ppm_eye_set(wave, info, 4, 24);
catch err
    caught = true;
    assert(strcmp(err.identifier, ...
        'build_ppm_eye_set:InconsistentAddressTrace'));
    assert(contains(err.message, sprintf('Block %d', perturbedBlock)));
end
assert(caught);
end

function checkMarkerWrapSafety()
info = fixtureInfo(20, 0.8, {'wrapped'});
desiredEyePhase = 15 + mod(0:(info.NumBlocks - 1), 3);
phaseWithoutDrift = desiredEyePhase - info.DriftSampleTrace;
info.UiSlipTrace = floor(phaseWithoutDrift / info.SamplesPerUi);
info.PhaseCodeTrace = mod(phaseWithoutDrift, info.SamplesPerUi);
info.EyePhaseUnwrappedTrace = info.UiSlipTrace * info.SamplesPerUi + ...
    info.PhaseCodeTrace + info.DriftSampleTrace;
wave = fixtureWaveform(info);
[eyes, ~] = build_ppm_eye_set(wave, info, 7, 40);
anchorEye = eyes(1);
blockStartUi = reconstructedBlockStarts(info);
windowBlocks = find(blockStartUi >= anchorEye.StartUi & ...
    blockStartUi < anchorEye.StartUi + anchorEye.UiCountUsed);
windowPhase = info.EyePhaseUnwrappedTrace(windowBlocks);
trueSpan = max(windowPhase) - min(windowPhase);

assert(anchorEye.Valid);
assert(isequal(info.EyePhaseUnwrappedTrace, desiredEyePhase));
assert(any(mod(windowPhase, info.SamplesPerUi) == 0));
assert(any(mod(windowPhase, info.SamplesPerUi) == info.SamplesPerUi - 1));
assert(anchorEye.MarkerSpanCode == trueSpan);
assert(anchorEye.MarkerSpanCode == 2);
markerCodes = [anchorEye.MarkerMinCode, anchorEye.MarkerMaxCode, ...
    anchorEye.MarkerCode];
assert(all(markerCodes >= 0 & markerCodes < info.SamplesPerUi));
assert(isequal(anchorEye.MarkerBlocks, ...
    [windowBlocks(1), windowBlocks(end)]));
assert(isequal(windowBlocks, ...
    anchorEye.MarkerBlocks(1):anchorEye.MarkerBlocks(2)));
end

function checkNaNAnchorAndTruncation()
info = fixtureInfo(12, 1.4, {'missing', 'present'});
anchorBlocks = [NaN 4];
wave = fixtureWaveform(info);
blockStartUi = reconstructedBlockStarts(info);
availableUi = blockStartUi(end) + info.AdcBlockUi - blockStartUi(1);
requested = availableUi + 50;
[eyes, setMeta] = build_ppm_eye_set(wave, info, anchorBlocks, requested);

assert(~eyes(1).Valid && ~isempty(eyes(1).Reason));
assert(eyes(2).Valid && eyes(end).Valid);
assert(eyes(2).Truncated && ~isempty(eyes(2).TruncationMessage));
assert(eyes(end).Truncated && ~isempty(eyes(end).TruncationMessage));
assert(eyes(2).UiCountUsed == ...
    blockStartUi(end) + info.AdcBlockUi - blockStartUi(anchorBlocks(2)));
assert(eyes(end).UiCountUsed == availableUi);
assert(eyes(end).StartUi == blockStartUi(1));
assert(setMeta.UiCountUsed(1) == 0);
assert(isequal(setMeta.UiCountUsed, [eyes.UiCountUsed]));
end

function checkInvalidInputsRejected()
info = fixtureInfo(10, 0, {'anchor'});
wave = fixtureWaveform(info);
requested = 24;
anchorBlocks = 4;

missingInfo = rmfield(info, 'DriftSampleTrace');
assertErrorId(@() build_ppm_eye_set(wave, missingInfo, ...
    anchorBlocks, requested), 'build_ppm_eye_set:MissingInfoField');
assertErrorId(@() build_ppm_eye_set(wave, 17, anchorBlocks, requested), ...
    'build_ppm_eye_set:InvalidInfo');
nonfiniteWave = wave;
nonfiniteWave(1) = NaN;
assertErrorId(@() build_ppm_eye_set(nonfiniteWave, info, ...
    anchorBlocks, requested), 'build_ppm_eye_set:InvalidCtLeSegment');

invalidInfo = info;
invalidInfo.PhaseCodeTrace(3) = 1.5;
assertErrorId(@() build_ppm_eye_set(wave, invalidInfo, ...
    anchorBlocks, requested), 'build_ppm_eye_set:InvalidInfoField');
invalidInfo = info;
invalidInfo.PhaseCodeTrace(3) = info.SamplesPerUi;
assertErrorId(@() build_ppm_eye_set(wave, invalidInfo, ...
    anchorBlocks, requested), 'build_ppm_eye_set:InvalidInfoField');
invalidInfo = info;
invalidInfo.UiSlipTrace(4) = invalidInfo.UiSlipTrace(3) - 20;
assertErrorId(@() build_ppm_eye_set(wave, invalidInfo, ...
    anchorBlocks, requested), 'build_ppm_eye_set:InvalidInfoField');
invalidInfo = info;
invalidInfo.AdcRange = [4 -4];
assertErrorId(@() build_ppm_eye_set(wave, invalidInfo, ...
    anchorBlocks, requested), 'build_ppm_eye_set:InvalidInfoField');
end

function checkMetaCompleteness()
info = fixtureInfo(24, 1.2, {'near', 'far'});
anchorBlocks = [5 16];
requested = 40;
wave = fixtureWaveform(info);
[eyes, setMeta] = build_ppm_eye_set(wave, info, anchorBlocks, requested);
documentedFields = {'RequestedUiCount', 'NumBlocks', ...
    'SelectedStartPhase', 'FreqOffsetPpm', 'SimulationEndUiExclusive', ...
    'AnchorBlocks', 'AnchorLabels', 'UiCountUsed', 'StartUi', ...
    'GlobalStartUi', 'MarkerCode', 'MarkerSpanCode', 'Valid', ...
    'Coefficients', 'Labels'};

assert(all([eyes.Valid]));
for fieldIndex = 1:numel(documentedFields)
    assert(isfield(setMeta, documentedFields{fieldIndex}));
end
assert(isequal(setMeta.UiCountUsed, [eyes.UiCountUsed]));
assert(isequal(setMeta.StartUi, [eyes.StartUi]));
assert(isequal(setMeta.GlobalStartUi, [eyes.GlobalStartUi]));
assert(isequal(setMeta.GlobalStartUi, ...
    info.AnalysisStartUi + setMeta.StartUi));
assert(isequal(setMeta.MarkerCode, [eyes.MarkerCode]));
assert(isequal(setMeta.MarkerSpanCode, [eyes.MarkerSpanCode]));
assert(isequal(setMeta.Valid, logical([eyes.Valid])));
assert(isequal(setMeta.AnchorBlocks, anchorBlocks));
assert(isequal(setMeta.AnchorLabels, info.AnchorLabels));
assert(isequal(setMeta.Labels, [info.AnchorLabels, {'final'}]));
end

function checkVariableAnchorCounts()
oneInfo = fixtureInfo(22, 0.9, {'single'});
oneWave = fixtureWaveform(oneInfo);
[oneEyes, oneMeta] = build_ppm_eye_set(oneWave, oneInfo, 8, 32);
assert(numel(oneEyes) == 2 && numel(oneMeta.Labels) == 2);
assert(strcmp(oneEyes(end).AnchorLabel, 'final'));
assert(isnan(oneEyes(end).AnchorBlock));
assert(oneEyes(end).StartUi == oneMeta.SimulationEndUiExclusive - 32);

threeLabels = {'first', 'second', 'third'};
threeInfo = fixtureInfo(30, 1.1, threeLabels);
threeWave = fixtureWaveform(threeInfo);
[threeEyes, threeMeta] = build_ppm_eye_set( ...
    threeWave, threeInfo, [4 12 21], 40);
assert(numel(threeEyes) == 4 && numel(threeMeta.Labels) == 4);
assert(strcmp(threeEyes(end).AnchorLabel, 'final'));
assert(strcmp(threeMeta.Labels{end}, 'final'));
assert(isnan(threeEyes(end).AnchorBlock));
assert(threeEyes(end).StartUi == ...
    threeMeta.SimulationEndUiExclusive - 40);
end

function checkAnchorLabels()
labels = ["alpha", "beta", "gamma"];
info = fixtureInfo(26, 0.7, labels);
anchorBlocks = [3 10 18];
wave = fixtureWaveform(info);
[eyes, setMeta] = build_ppm_eye_set(wave, info, anchorBlocks, 32);

for anchorIndex = 1:numel(anchorBlocks)
    expectedLabel = char(labels(anchorIndex));
    assert(strcmp(eyes(anchorIndex).AnchorLabel, expectedLabel));
    assert(contains(eyes(anchorIndex).FixedTapLabel, expectedLabel));
    assert(contains(eyes(anchorIndex).FixedTapReason, expectedLabel));
    assert(strcmp(setMeta.AnchorLabels{anchorIndex}, expectedLabel));
end
assert(strcmp(eyes(end).AnchorLabel, 'final'));

badInfo = info;
badInfo.AnchorLabels = {'only', 'two'};
assertErrorId(@() build_ppm_eye_set(wave, badInfo, ...
    anchorBlocks, 32), 'build_ppm_eye_set:InvalidInfoField');
end

function info = fixtureInfo(numBlocks, driftRatePerBlock, labels)
samplesPerUi = 16;
adcBlockUi = 8;
blockIndex = 0:(numBlocks - 1);
driftSampleTrace = round(driftRatePerBlock * blockIndex);
targetEyePhase = 7;
phaseWithoutDrift = targetEyePhase - driftSampleTrace;
uiSlipTrace = floor(phaseWithoutDrift / samplesPerUi);
phaseCodeTrace = mod(phaseWithoutDrift, samplesPerUi);
coefficientTrace = repmat([0.08 -0.05 1 -0.11 0.04 0.01], ...
    numBlocks, 1);
coefficientTrace(:, 1) = 0.08 + 0.002 * blockIndex.';
coefficientTrace(:, 4) = -0.11 + 0.001 * blockIndex.';

info = struct();
info.SelectedStartPhase = targetEyePhase;
info.SamplesPerUi = samplesPerUi;
info.NumBlocks = numBlocks;
info.AdcBlockUi = adcBlockUi;
info.BaseUi = 16;
info.AnalysisStartUi = 1000;
info.PreTapCount = 2;
info.AdcBits = 7;
info.AdcRange = [-4 4];
info.FreqOffsetPpm = 1e6 * driftRatePerBlock / ...
    (adcBlockUi * samplesPerUi);
info.AnchorLabels = labels;
info.PhaseCodeTrace = phaseCodeTrace;
info.UiSlipTrace = uiSlipTrace;
info.DriftSampleTrace = driftSampleTrace;
info.EyePhaseUnwrappedTrace = uiSlipTrace * samplesPerUi + ...
    phaseCodeTrace + driftSampleTrace;
info.FfeCoeffTrace = coefficientTrace;
end

function blockStartUi = reconstructedBlockStarts(info)
blockIndex = 0:(info.NumBlocks - 1);
absSample0 = (info.BaseUi + blockIndex * info.AdcBlockUi + ...
    info.UiSlipTrace) * info.SamplesPerUi + info.PhaseCodeTrace + ...
    info.DriftSampleTrace;
blockStartUi = floor(absSample0 / info.SamplesPerUi);
end

function wave = fixtureWaveform(info)
blockStartUi = reconstructedBlockStarts(info);
totalUi = blockStartUi(end) + info.AdcBlockUi + info.PreTapCount;
t = (0:(totalUi * info.SamplesPerUi - 1)) / info.SamplesPerUi;
pam4Pattern = [-3 -1 3 1 -1 1 -3 3];
symbolIndex = mod(0:(totalUi - 1), numel(pam4Pattern)) + 1;
symbol = pam4Pattern(symbolIndex);
wave = 0.85 * repelem(symbol / 3, info.SamplesPerUi) + ...
    0.11 * sin(2 * pi * 0.37 * t + 0.19) + ...
    0.05 * cos(2 * pi * 0.83 * t - 0.13);
end

function assertErrorId(functionHandle, expectedIdentifier)
caught = false;
try
    functionHandle();
catch err
    caught = true;
    assert(strcmp(err.identifier, expectedIdentifier));
end
assert(caught);
end
