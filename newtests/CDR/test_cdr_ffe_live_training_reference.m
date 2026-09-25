function test_cdr_ffe_live_training_reference
%TEST_CDR_FFE_LIVE_TRAINING_REFERENCE Fixed and pre-update live DLEV refs.

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
    'DlevOuterInit', 48, ...
    'DlevInnerInit', 16, ...
    'FfeTrainingOuterRef', 36, ...
    'FfeTrainingInnerRef', 12, ...
    'FfeFreezeEnable', false, ...
    'EyeDiagramEnable', false, ...
    'SaveOutputs', false, ...
    'FfeStepSize', 0.0018, ...
    'FfeStepSizeSettle', 0.0002);

% Group 1: omitted mode is exactly fixed mode, including reference timing.
[~, fixedDefault] = evalc('cdr_dlev_cdrffe_sslms_v3(opts)');
fixedOpts = opts;
fixedOpts.FfeTrainingReferenceMode = 'fixed';
[~, fixedExplicit] = evalc('cdr_dlev_cdrffe_sslms_v3(fixedOpts)');
exactFields = {'PhaseCodeTrace', 'FfeCoeffTrace', 'DlevInnerTrace', ...
    'DlevOuterTrace', 'FfeRawDeltaTrace', 'FfeAppliedDeltaTrace'};
assertExactFields(fixedDefault, fixedExplicit, exactFields);
assert(strcmp(fixedDefault.Mode, 'fixed'));
assert(strcmp(fixedExplicit.Mode, 'fixed'));
assert(isequal(size(fixedDefault.FfeTrainingInnerRefTrace), ...
    size(fixedDefault.DlevInnerTrace)));
assert(isequal(size(fixedDefault.FfeTrainingOuterRefTrace), ...
    size(fixedDefault.DlevOuterTrace)));
expectedActive = false(size(fixedDefault.FfeTrainingActiveTrace));
expectedActive(:, 1:128) = true;
assert(islogical(fixedDefault.FfeTrainingActiveTrace));
assert(isequal(fixedDefault.FfeTrainingActiveTrace, expectedActive));
assert(all(fixedDefault.FfeTrainingInnerRefTrace(:, 1:128) == 12, 'all'));
assert(all(fixedDefault.FfeTrainingOuterRefTrace(:, 1:128) == 36, 'all'));
assert(all(isnan(fixedDefault.FfeTrainingInnerRefTrace(:, 129:end)), 'all'));
assert(all(isnan(fixedDefault.FfeTrainingOuterRefTrace(:, 129:end)), 'all'));

% Group 2: live mode consumes each block's pre-DLEV-update values exactly.
liveOpts = opts;
liveOpts.FfeTrainingReferenceMode = "LIVE-DLEV";
[~, live] = evalc('cdr_dlev_cdrffe_sslms_v3(liveOpts)');
assert(strcmp(live.Mode, 'live-dlev'));
assert(live.FfeTrainingInnerRefTrace(1, 1) == 16);
assert(live.FfeTrainingOuterRefTrace(1, 1) == 48);
assert(isequal(live.FfeTrainingInnerRefTrace(:, 1), ...
    live.DlevInnerTrace(:, 1)));
assert(isequal(live.FfeTrainingOuterRefTrace(:, 1), ...
    live.DlevOuterTrace(:, 1)));
assert(isequal(live.FfeTrainingInnerRefTrace(:, 2:128), ...
    live.DlevInnerTrace(:, 1:127)));
assert(isequal(live.FfeTrainingOuterRefTrace(:, 2:128), ...
    live.DlevOuterTrace(:, 1:127)));
assert(isequal(live.FfeTrainingActiveTrace, expectedActive));
liveRefChanges = [diff(live.FfeTrainingInnerRefTrace(:, 1:128), 1, 2), ...
    diff(live.FfeTrainingOuterRefTrace(:, 1:128), 1, 2)];
assert(any(liveRefChanges(:) ~= 0), 'Live references never followed an update.');
liveUpdates = live.FfeAppliedDeltaTrace(:, 1:128, :);
assert(any(liveUpdates(:) ~= 0), 'Live training produced no known update.');
assert(~isequaln(live.FfeAppliedDeltaTrace(:, 1:128, :), ...
    fixedDefault.FfeAppliedDeltaTrace(:, 1:128, :)));
assert(~isequaln(live.FfeCoeffTrace, fixedDefault.FfeCoeffTrace));

% Group 3: programmed fixed references are ignored completely in live mode.
otherLiveOpts = liveOpts;
otherLiveOpts.FfeTrainingOuterRef = 99;
otherLiveOpts.FfeTrainingInnerRef = 33;
[~, otherLive] = evalc('cdr_dlev_cdrffe_sslms_v3(otherLiveOpts)');
liveFields = {'PhaseCodeTrace', 'FfeCoeffTrace', 'DlevInnerTrace', ...
    'DlevOuterTrace', 'FfeRawDeltaTrace', 'FfeAppliedDeltaTrace', ...
    'FfeTrainingInnerRefTrace', 'FfeTrainingOuterRefTrace', ...
    'FfeTrainingActiveTrace'};
assertExactFields(live, otherLive, liveFields);

% Group 4: with training disabled, both modes are dynamically identical.
noTrainingFixed = opts;
noTrainingFixed.FfeTrainingBlocks = 0;
noTrainingFixed.FfeInitMode = 'planA';
noTrainingFixed.FfeReleaseMode = 'concurrent';
noTrainingFixed.FfeTrainingReferenceMode = 'fixed';
noTrainingLive = noTrainingFixed;
noTrainingLive.FfeTrainingReferenceMode = 'live-dlev';
[~, disabledFixed] = evalc('cdr_dlev_cdrffe_sslms_v3(noTrainingFixed)');
[~, disabledLive] = evalc('cdr_dlev_cdrffe_sslms_v3(noTrainingLive)');
dynamicFields = {'PhaseCodeTrace', 'FfeCoeffTrace', 'DlevInnerTrace', ...
    'DlevOuterTrace', 'FfeRawDeltaTrace', 'FfeAppliedDeltaTrace'};
assertExactFields(disabledFixed, disabledLive, dynamicFields);
for value = {disabledFixed, disabledLive}
    result = value{1};
    assert(islogical(result.FfeTrainingActiveTrace));
    assert(~any(result.FfeTrainingActiveTrace, 'all'));
    assert(all(isnan(result.FfeTrainingInnerRefTrace), 'all'));
    assert(all(isnan(result.FfeTrainingOuterRefTrace), 'all'));
end

% Group 5: invalid modes fail with the contract ID before cache access.
badBase = opts;
badBase.CosimDir = [tempname '_missing_cosim'];
invalidModes = {'', 'other', 7, true, string("unknown"), ...
    ["fixed", "live-dlev"], {'fixed'}};
expectedId = 'cdr_dlev_cdrffe_sslms_v3:InvalidFfeTrainingReferenceMode';
for k = 1:numel(invalidModes)
    bad = badBase;
    bad.FfeTrainingReferenceMode = invalidModes{k};
    assertThrows(@() cdr_dlev_cdrffe_sslms_v3(bad), expectedId);
end

fprintf('test_cdr_ffe_live_training_reference: 5/5 groups passed.\n');
end

function assertExactFields(first, second, fieldNames)
for k = 1:numel(fieldNames)
    name = fieldNames{k};
    assert(isequaln(first.(name), second.(name)), ...
        '%s differed unexpectedly.', name);
end
end

function assertThrows(action, expectedId)
try
    action();
catch caught
    assert(strcmp(caught.identifier, expectedId), ...
        'Expected error %s, received %s.', expectedId, caught.identifier);
    return;
end
error('Expected error %s was not thrown.', expectedId);
end

function restoreEnvironment(oldPath, oldRng)
path(oldPath);
rng(oldRng);
end
