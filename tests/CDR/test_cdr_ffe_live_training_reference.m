function test_cdr_ffe_live_training_reference
%TEST_CDR_FFE_LIVE_TRAINING_REFERENCE Fixed/live FFE-reference contract.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
oldPath = path;
oldRng = rng;
cleanup = onCleanup(@() restoreEnvironment(oldPath, oldRng)); %#ok<NASGU>
suiteRoot = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe');
addpath(suiteRoot, '-begin');
setup_cdr_dlev_cdrffe_paths();

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
    'FfeTrainingReferenceMode', 'fixed', ...
    'FfeFreezeEnable', false, ...
    'SaveOutputs', false, ...
    'EyeDiagramEnable', false);

% Group 1: explicit fixed mode is self-consistent. This base opts pins
% FfeTrainingReferenceMode='fixed' rather than relying on the option default
% (currently 'live-dlev'); groups 2-5 override the mode explicitly.
base = runCase(opts);
fixedOpts = opts;
fixedOpts.FfeTrainingReferenceMode = 'fixed';
fixed = runCase(fixedOpts);
assertMode(base, 'fixed');
assertMode(fixed, 'fixed');
compareFields(base, fixed, {'PhaseCodeTrace', 'FfeCoeffTrace', ...
    'DlevInnerTrace', 'DlevOuterTrace', 'FfeRawDeltaTrace'});
assertReferenceTrace(base, 12, 36, 128);
assertReferenceTrace(fixed, 12, 36, 128);

% Group 2: live references are the DLEV values before each DLEV update.
liveOpts = opts;
liveOpts.FfeTrainingReferenceMode = 'LIVE-DLEV';
live = runCase(liveOpts);
assertMode(live, 'live-dlev');
assert(live.FfeTrainingInnerRefTrace(1, 1) == 16);
assert(live.FfeTrainingOuterRefTrace(1, 1) == 48);
assert(isequal(live.FfeTrainingInnerRefTrace(1, 2:128), ...
    live.DlevInnerTrace(1, 1:127)));
assert(isequal(live.FfeTrainingOuterRefTrace(1, 2:128), ...
    live.DlevOuterTrace(1, 1:127)));
assert(any(diff(live.FfeTrainingInnerRefTrace(1, 1:128)) ~= 0) || ...
    any(diff(live.FfeTrainingOuterRefTrace(1, 1:128)) ~= 0), ...
    'Live references never followed a changing DLEV trajectory.');
assert(~isequaln(live.FfeCoeffTrace, fixed.FfeCoeffTrace), ...
    'Live and fixed reference modes produced identical FFE coefficients.');
assert(all(isnan(live.FfeRawDeltaTrace(1, 1, :)), 'all'), ...
    'The first-block raw FFE delta must be NaN.');
assert(all(isnan(live.FfeTrainingInnerRefTrace(:, 129:end)), 'all'));
assert(all(isnan(live.FfeTrainingOuterRefTrace(:, 129:end)), 'all'));
assert(all(live.FfeTrainingActiveTrace(:, 1:128), 'all'));
assert(~any(live.FfeTrainingActiveTrace(:, 129:end), 'all'));

% Group 3: configured constants remain valid but are unused in live mode.
unusedOpts = liveOpts;
unusedOpts.FfeTrainingOuterRef = 99;
unusedOpts.FfeTrainingInnerRef = 33;
unused = runCase(unusedOpts);
assert(unused.FfeTrainingOuterRef == 99 && unused.FfeTrainingOuterRef > 0);
assert(unused.FfeTrainingInnerRef == 33 && unused.FfeTrainingInnerRef > 0);
compareFields(live, unused, {'PhaseCodeTrace', 'FfeCoeffTrace', ...
    'FfeRawDeltaTrace', 'DlevInnerTrace', 'DlevOuterTrace', ...
    'FfeTrainingInnerRefTrace', 'FfeTrainingOuterRefTrace', ...
    'FfeTrainingActiveTrace'});

% Group 4: with no training, fixed/live modes have identical dynamics.
noTraining = opts;
noTraining.FfeTrainingBlocks = 0;
noTraining.FfeInitMode = 'planA';
noTraining.FfeReleaseMode = 'concurrent';
noTraining.FfeTrainingReferenceMode = 'fixed';
noTrainingFixed = runCase(noTraining);
noTraining.FfeTrainingReferenceMode = 'live-dlev';
noTrainingLive = runCase(noTraining);
compareFields(noTrainingFixed, noTrainingLive, {'PhaseCodeTrace', ...
    'FfeCoeffTrace', 'FfeRawDeltaTrace', 'DlevInnerTrace', ...
    'DlevOuterTrace', 'FfeTrainingInnerRefTrace', ...
    'FfeTrainingOuterRefTrace', 'FfeTrainingActiveTrace'});
assert(all(isnan(noTrainingFixed.FfeTrainingInnerRefTrace), 'all'));
assert(all(isnan(noTrainingFixed.FfeTrainingOuterRefTrace), 'all'));
assert(~any(noTrainingFixed.FfeTrainingActiveTrace, 'all'));
assert(all(isnan(noTrainingLive.FfeTrainingInnerRefTrace), 'all'));
assert(all(isnan(noTrainingLive.FfeTrainingOuterRefTrace), 'all'));
assert(~any(noTrainingLive.FfeTrainingActiveTrace, 'all'));

% Group 5: invalid modes fail validation before a cache lookup.
expectedId = 'cdr_dlev_cdrffe_sslms_v3:InvalidFfeTrainingReferenceMode';
badBase = opts;
badBase.CosimDir = [tempname '_nonexistent_cosim'];
invalidModes = {[], '', 'bad', 42, true, {'fixed'}, ...
    ['fixed'; 'other'], ["fixed", "live-dlev"]};
for k = 1:numel(invalidModes)
    bad = badBase;
    bad.FfeTrainingReferenceMode = invalidModes{k};
    assertThrows(@() cdr_dlev_cdrffe_sslms_v3(bad), expectedId);
end

fprintf('test_cdr_ffe_live_training_reference: 5/5 groups passed.\n');
end

function result = runCase(opts)
rng(1, 'twister');
[~, result] = evalc('cdr_dlev_cdrffe_sslms_v3(opts)');
end

function assertMode(result, expected)
assert(strcmp(result.FfeTrainingReferenceMode, expected));
assert(strcmp(result.RunOptions.FfeTrainingReferenceMode, expected));
end

function assertReferenceTrace(result, innerRef, outerRef, trainingBlocks)
assert(isequal(size(result.FfeTrainingInnerRefTrace), ...
    size(result.FfeTrainingOuterRefTrace)));
assert(isequal(size(result.FfeTrainingInnerRefTrace), ...
    size(result.FfeTrainingActiveTrace)));
assert(all(result.FfeTrainingInnerRefTrace(:, 1:trainingBlocks) == innerRef, 'all'));
assert(all(result.FfeTrainingOuterRefTrace(:, 1:trainingBlocks) == outerRef, 'all'));
assert(all(isnan(result.FfeTrainingInnerRefTrace(:, trainingBlocks + 1:end)), 'all'));
assert(all(isnan(result.FfeTrainingOuterRefTrace(:, trainingBlocks + 1:end)), 'all'));
assert(all(result.FfeTrainingActiveTrace(:, 1:trainingBlocks), 'all'));
assert(~any(result.FfeTrainingActiveTrace(:, trainingBlocks + 1:end), 'all'));
end

function compareFields(left, right, fields)
for k = 1:numel(fields)
    name = fields{k};
    assert(isequaln(left.(name), right.(name)), '%s differs.', name);
end
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
