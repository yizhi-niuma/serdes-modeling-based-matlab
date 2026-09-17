function test_build_cdr_ffe_eye
%TEST_BUILD_CDR_FFE_EYE Targeted regression checks for fixed-tap eye helpers.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
helperDir = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe');
tiAdcDir = fullfile(repoRoot, 'src', 'ADC', 'TI_ADC');
cdrDir = fullfile(repoRoot, 'src', 'CDR');
addpath(tiAdcDir, '-begin');
addpath(cdrDir, '-begin');
addpath(helperDir, '-begin');

assertSamePath(which('sar_adc_core'), fullfile(tiAdcDir, 'sar_adc_core.m'));
rng(8675309, 'twister');

testMainOnlyAndShape();
testSixTapDirectRegressor();
testRowColumnParityAndOddCount();
testUnsignedIntegerScalarsAndNoRescaling();
testIdealSarLaneEquivalence();
testValidationFailures();
testRenderingDisabled();

fprintf('test_build_cdr_ffe_eye passed 7 / 7 checks.\n');
end

function testMainOnlyAndShape()
sps = 8;
totalUi = 18;
startUi = 5;
uiCount = 7;
bits = 7;
adcRange = [-0.8 0.8];
waveform = syntheticWaveform(sps, totalUi, 0.62);
coefficients = [0 0 1 0 0 0];
preTapCount = 2;

eye = build_cdr_ffe_eye(waveform, startUi, uiCount, sps, ...
    coefficients, preTapCount, bits, adcRange);
adc = sar_adc_core(adcRange(1), adcRange(2), bits);
allCodes = double(adc.convertVectorFast(waveform)) - 2^(bits - 1);
targetCodes = allCodes(startUi * sps + (1:(uiCount * sps)));
expectedGrid = reshape(targetCodes, sps, uiCount);

assert(eye.Valid && isempty(eye.Reason));
assert(isequal(eye.OutputCodeGrid, expectedGrid));
assert(isequal(size(eye.OutputCodeGrid), [sps uiCount]));
assert(isequal(eye.PhaseUi, (0:(2 * sps - 1)) / sps));
assert(eye.UiCountUsed == uiCount && eye.StartUi == startUi);
assert(eye.TraceCount == uiCount - 1);
assert(isequal(eye.Coefficients, coefficients));
assert(all(abs(diff(eye.CodeBinEdges) - 0.5) < 10 * eps));
assert(numel(eye.CodeBinEdges) == numel(eye.CodeBinCenters) + 1);
assert(eye.CodeBinEdges(1) <= min(expectedGrid(:)));
assert(eye.CodeBinEdges(end) >= max(expectedGrid(:)));
assert(sum(eye.Density(:)) == 2 * sps * (uiCount - 1));
end

function testSixTapDirectRegressor()
sps = 16;
totalUi = 24;
startUi = 6;
uiCount = 9;
bits = 8;
adcRange = [-1 1];
waveform = syntheticWaveform(sps, totalUi, 0.83);
coefficients = [0.125 -0.25 1 0.375 -0.125 0.0625];
preTapCount = 2;
mainTapIndex = preTapCount + 1;

eye = build_cdr_ffe_eye(waveform, startUi, uiCount, sps, ...
    coefficients, preTapCount, bits, adcRange);
adc = sar_adc_core(adcRange(1), adcRange(2), bits);
sourceGrid = reshape(double(adc.convertVectorFast(waveform)) - 2^(bits - 1), sps, totalUi);
expected = zeros(sps, uiCount);
for phaseIndex = 1:sps
    for targetIndex = 1:uiCount
        for tapIndex = 1:numel(coefficients)
            sourceUi = startUi + targetIndex + mainTapIndex - tapIndex;
            expected(phaseIndex, targetIndex) = expected(phaseIndex, targetIndex) + ...
                coefficients(tapIndex) * sourceGrid(phaseIndex, sourceUi);
        end
    end
end

assert(max(abs(eye.OutputCodeGrid(:) - expected(:))) < 1e-12);
assert(eye.Minimum == min(expected(:)));
assert(eye.Maximum == max(expected(:)));
assert(sum(eye.Density(:)) == 2 * sps * (uiCount - 1));
end

function testRowColumnParityAndOddCount()
sps = 8;
waveformRow = syntheticWaveform(sps, 17, 0.55);
coefficients = [0.1 -0.2 1 0.25 -0.1 0.05];
args = {4, 5, sps, coefficients, 2, 7, [-0.75 0.75]};
rowEye = build_cdr_ffe_eye(waveformRow, args{:});
columnEye = build_cdr_ffe_eye(waveformRow.', args{:});

assert(isequal(rowEye.OutputCodeGrid, columnEye.OutputCodeGrid));
assert(isequal(rowEye.Density, columnEye.Density));
assert(rowEye.UiCountUsed == 5 && rowEye.TraceCount == 4);
end

function testUnsignedIntegerScalarsAndNoRescaling()
sps = uint16(8);
totalUi = 14;
startUi = uint16(4);
uiCount = uint16(5);
bits = uint16(6);
waveform = uint16(mod((0:(double(sps) * totalUi - 1)) * 17, 256));
coefficients = [0 0 1 0 0 0];
eye = build_cdr_ffe_eye(waveform, startUi, uiCount, sps, ...
    coefficients, uint16(2), bits, uint16([0 255]));
adc = sar_adc_core(0, 255, double(bits));
rawCodes = double(adc.convertVectorFast(double(waveform)));
firstTarget = double(startUi) * double(sps) + 1;
lastTarget = (double(startUi) + double(uiCount)) * double(sps);
expected = reshape(rawCodes(firstTarget:lastTarget) - 2^(double(bits) - 1), ...
    double(sps), double(uiCount));

assert(isequal(eye.OutputCodeGrid, expected));
% If the helper had normalized or rescaled input amplitude, this direct
% repository-SAR comparison would differ for this deliberately uncentered grid.
assert(any(expected(:) == -2^(double(bits) - 1)) || any(expected(:) == 2^(double(bits) - 1) - 1));
end

function testIdealSarLaneEquivalence()
bits = 7;
adcRange = [-1 1];
lsb = diff(adcRange) / 2^bits;
thresholds = adcRange(1) + (1:10) * lsb;
boundarySamples = [adcRange(1), thresholds, 0, adcRange(2), ...
    adcRange(1) - lsb, adcRange(2) + lsb];
randomSamples = adcRange(1) + diff(adcRange) * rand(1, 64 - numel(boundarySamples));
vin = [boundarySamples randomSamples];
vectorAdc = sar_adc_core(adcRange(1), adcRange(2), bits);
vectorCodes = vectorAdc.convertVectorFast(vin);

laneAdc = ti_adc_core(64, adcRange(1), adcRange(2), bits);
laneCodes = laneAdc.convertOneBlockFast(vin);
assert(isequal(vectorCodes, laneCodes));

% A second block with serially reordered samples verifies lane identity, not
% merely equality for a favorable first block ordering.
permutation = [2:2:64 1:2:64];
assert(isequal(vectorAdc.convertVectorFast(vin(permutation)), ...
    laneAdc.convertOneBlockFast(vin(permutation))));
assert(vectorCodes(1) == 0);
assert(vectorCodes(find(vin == adcRange(2), 1)) == 2^bits - 1);
zeroIndex = find(vin == 0, 1);
assert(vectorCodes(zeroIndex) == 2^(bits - 1) - 1); % SAR equality clears the trial bit.
end

function testValidationFailures()
baseWaveform = syntheticWaveform(8, 12, 0.5);
coefficients = [0 0 1 0 0 0];
validTail = {8, coefficients, 2, 7, [-1 1]};
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2, 1, validTail{:}), ...
    'build_cdr_ffe_eye:InvalidUiCount');
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2.5, 4, validTail{:}), ...
    'build_cdr_ffe_eye:InvalidStartUi');
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2, 4.5, validTail{:}), ...
    'build_cdr_ffe_eye:InvalidUiCount');
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2, 4, 0, coefficients, 2, 7, [-1 1]), ...
    'build_cdr_ffe_eye:InvalidSamplesPerUi');
assertThrowsId(@() build_cdr_ffe_eye([baseWaveform NaN], 3, 4, validTail{:}), ...
    'build_cdr_ffe_eye:InvalidCtLeSegment');
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2, 4, 8, [0 0 0.9 0 0 0], 2, 7, [-1 1]), ...
    'build_cdr_ffe_eye:InvalidMainTap');
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2, 4, 8, coefficients, 6, 7, [-1 1]), ...
    'build_cdr_ffe_eye:InvalidPreTapCount');
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2, 4, 8, coefficients, 2, 0, [-1 1]), ...
    'build_cdr_ffe_eye:InvalidAdcBits');
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2, 4, 8, coefficients, 2, 7, [1 -1]), ...
    'build_cdr_ffe_eye:InvalidAdcRange');
% Six taps with two pre-taps require three complete UIs to the left.
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 2, 4, validTail{:}), ...
    'build_cdr_ffe_eye:InsufficientMargin');
assertThrowsId(@() build_cdr_ffe_eye(baseWaveform, 5, 6, validTail{:}), ...
    'build_cdr_ffe_eye:InsufficientMargin');
end

function testRenderingDisabled()
validEye = build_cdr_ffe_eye(syntheticWaveform(8, 14, 0.5), 4, 5, 8, ...
    [0 0 1 0 0 0], 2, 7, [-1 1]);
invalidEye = struct('Valid', false, 'Reason', 'No final lock was available.');
resultDir = fullfile(tempdir, ['cdr_ffe_eye_disabled_' sprintf('%08x', randi(2^31 - 1))]);
config = struct();
config.ResultDir = resultDir;
config.SelectedStartPhase = 3;
config.FreezeBlock = 12;
config.FreezeCenterCode = 11;
config.FinalLockCode = NaN;
config.UiCountRequested = 5;
config.SaveOutputs = false;
paths = plot_cdr_ffe_eyes(validEye, invalidEye, config);
assert(isequal(paths, struct('Freeze', '', 'Final', '', 'Comparison', '')));
assert(~exist(resultDir, 'dir'));
end

function waveform = syntheticWaveform(sps, uiCount, amplitude)
time = (0:(sps * uiCount - 1)) / sps;
symbols = 2 * (rand(1, uiCount) > 0.5) - 1;
symbolWaveform = repelem(symbols, sps);
waveform = amplitude * (0.78 * symbolWaveform + 0.16 * sin(2 * pi * time) + ...
    0.06 * sin(2 * pi * 0.37 * time + 0.2));
end

function assertThrowsId(testFcn, expectedId)
didThrow = false;
try
    testFcn();
catch err
    didThrow = true;
    assert(strcmp(err.identifier, expectedId), ...
        'Expected error %s, received %s (%s).', expectedId, err.identifier, err.message);
end
assert(didThrow, 'Expected error %s was not thrown.', expectedId);
end

function assertSamePath(actualPath, expectedPath)
actualPath = strrep(char(actualPath), '\', '/');
expectedPath = strrep(char(expectedPath), '\', '/');
if ispc
    isMatch = strcmpi(actualPath, expectedPath);
else
    isMatch = strcmp(actualPath, expectedPath);
end
assert(isMatch, 'Expected path %s, resolved %s.', expectedPath, actualPath);
end
