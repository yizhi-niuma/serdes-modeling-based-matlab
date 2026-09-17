function test_cdr_ffe_training_reference
%TEST_CDR_FFE_TRAINING_REFERENCE Separate DLEV initialization and training refs.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
oldPath = path;
oldRng = rng;
cleanup = onCleanup(@() restoreEnvironment(oldPath, oldRng)); %#ok<NASGU>
addpath(fullfile(repoRoot, 'validation', 'CDR', ...
    'test_cdr_dlev_cdrffe'), '-begin');
rng(1, 'twister');

opts = struct( ...
    'CosimDir', 'channel_ctle_cosim', ...
    'TxFile', 'tx_prbs20.mat', ...
    'AnalysisNumUi', 256 * 64 + 512, ...
    'StartPhaseList', 20, ...
    'FfeTrainingBlocks', 128, ...
    'FfeFreezeEnable', false, ...
    'EyeDiagramEnable', false, ...
    'SaveOutputs', false, ...
    'FfeStepSize', 0.0018, ...
    'FfeStepSizeSettle', 0.0002);

% Group 1: defaults keep initialization at 48/16 and train at 36/12.
[~, base] = evalc('cdr_dlev_cdrffe_sslms_v3(opts)');
assert(base.DlevInnerTrace(1) == 16);
assert(base.DlevOuterTrace(1) == 48);
assert(base.DlevInnerInit == 16 && base.DlevOuterInit == 48);
assert(base.FfeTrainingInnerRef == 12 && base.FfeTrainingOuterRef == 36);
assert(base.RunOptions.DlevInnerInit == 16);
assert(base.RunOptions.DlevOuterInit == 48);
assert(base.RunOptions.FfeTrainingInnerRef == 12);
assert(base.RunOptions.FfeTrainingOuterRef == 36);
assert(~base.FfeAdaptationCalculatedTrace(1, 1), ...
    'First block skips FFE adaptation.');
assert(all(isnan(base.FfeRawDeltaTrace(1, 1, :)), 'all'));
assert(all(base.FfeAppliedDeltaTrace(1, 1, :) == 0, 'all'));

% Group 2: name/value DLEV initialization does not move training refs.
opts2 = opts;
opts2.DlevOuterInit = 20;
opts2.DlevInnerInit = 7;
args = structToNameValue(opts2);
[~, initOnly] = evalc('cdr_dlev_cdrffe_sslms_v3(args{:})');
assert(initOnly.DlevInnerTrace(1) == 7);
assert(initOnly.DlevOuterTrace(1) == 20);
assert(initOnly.DlevInnerInit == 7 && initOnly.DlevOuterInit == 20);
assert(initOnly.FfeTrainingInnerRef == 12);
assert(initOnly.FfeTrainingOuterRef == 36);
assert(initOnly.RunOptions.DlevInnerInit == 7);
assert(initOnly.RunOptions.DlevOuterInit == 20);
assert(initOnly.RunOptions.FfeTrainingInnerRef == 12);
assert(initOnly.RunOptions.FfeTrainingOuterRef == 36);

% Group 3: changing only training refs changes active training behavior.
trainingOpts = opts;
trainingOpts.FfeTrainingOuterRef = 48;
trainingOpts.FfeTrainingInnerRef = 16;
[~, trainingRef] = evalc('cdr_dlev_cdrffe_sslms_v3(trainingOpts)');
assert(trainingRef.FfeTrainingInnerRef == 16);
assert(trainingRef.FfeTrainingOuterRef == 48);
assert(trainingRef.RunOptions.FfeTrainingInnerRef == 16);
assert(trainingRef.RunOptions.FfeTrainingOuterRef == 48);
assert(trainingRef.DlevInnerTrace(1) == base.DlevInnerTrace(1));
assert(trainingRef.DlevOuterTrace(1) == base.DlevOuterTrace(1));
coeffDifference = trainingRef.FfeCoeffTrace(1, 1:128, :) - ...
    base.FfeCoeffTrace(1, 1:128, :);
assert(any(coeffDifference(:) ~= 0), ...
    'Training references must affect coefficients during training.');

% Group 4: training refs are inert when the training phase is disabled.
baseDD = opts;
baseDD.FfeTrainingBlocks = 0;
baseDD.FfeInitMode = 'planA';
baseDD.FfeReleaseMode = 'concurrent';
refsA = baseDD;
refsA.FfeTrainingOuterRef = 36;
refsA.FfeTrainingInnerRef = 12;
refsB = baseDD;
refsB.FfeTrainingOuterRef = 48;
refsB.FfeTrainingInnerRef = 16;
[~, ddA] = evalc('cdr_dlev_cdrffe_sslms_v3(refsA)');
[~, ddB] = evalc('cdr_dlev_cdrffe_sslms_v3(refsB)');
inertFields = {'PhaseCodeTrace', 'DlevInnerTrace', 'DlevOuterTrace', ...
    'FfeCoeffTrace', 'FfeRawDeltaTrace'};
for k = 1:numel(inertFields)
    fieldName = inertFields{k};
    assert(isequaln(ddA.(fieldName), ddB.(fieldName)), ...
        '%s changed despite disabled FFE training.', fieldName);
end

% Group 5: reject every invalid reference before touching cache inputs.
expectedId = 'cdr_dlev_cdrffe_sslms_v3:InvalidFfeTrainingReference';
badBase = opts;
badBase.CosimDir = [tempname '_missing_cosim'];
invalidRefs = {0, -1, NaN, Inf, [12 13], 36 + 1i, string('48'), '48'};
for k = 1:numel(invalidRefs)
    bad = badBase;
    bad.FfeTrainingOuterRef = invalidRefs{k};
    bad.FfeTrainingInnerRef = 12;
    assertThrows(@() cdr_dlev_cdrffe_sslms_v3(bad), expectedId);
end
for k = 1:numel(invalidRefs)
    bad = badBase;
    bad.FfeTrainingOuterRef = 36;
    bad.FfeTrainingInnerRef = invalidRefs{k};
    assertThrows(@() cdr_dlev_cdrffe_sslms_v3(bad), expectedId);
end
for outerRef = [12 11]
    bad = badBase;
    bad.FfeTrainingOuterRef = outerRef;
    bad.FfeTrainingInnerRef = 12;
    assertThrows(@() cdr_dlev_cdrffe_sslms_v3(bad), expectedId);
end

fprintf('test_cdr_ffe_training_reference: 5/5 groups passed.\n');
end

function args = structToNameValue(value)
names = fieldnames(value);
values = struct2cell(value);
args = reshape([names.'; values.'], 1, []);
end

function assertThrows(action, expectedId)
threw = false;
try
    action();
catch caught
    threw = true;
    assert(strcmp(caught.identifier, expectedId), ...
        'Expected error %s, received %s.', expectedId, caught.identifier);
end
assert(threw, 'Expected error %s was not thrown.', expectedId);
end

function restoreEnvironment(oldPath, oldRng)
path(oldPath);
rng(oldRng);
end
