function test_cdr_ffe_freeze_integration
%TEST_CDR_FFE_FREEZE_INTEGRATION End-to-end invariants for v3 FFE freeze.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
oldPath = path;
oldRng = rng;
outputDir = [tempname '_cdr_ffe_freeze'];
cleanup = onCleanup(@() restoreEnvironment(oldPath, oldRng, outputDir)); %#ok<NASGU>
suiteRoot = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe');
addpath(suiteRoot);
setup_cdr_dlev_cdrffe_paths();

opts = struct();
% Pin behavioral write-freeze regression independently of tuned defaults.
opts.CosimDir = 'channel_ctle_cosim'; opts.TxFile = 'tx_prbs20.mat'; opts.Kp = 8; opts.Ki = .03; opts.MaxDeltaCode = 12; opts.PdOffset = -.05; opts.StepSize = .3; opts.StepSizeSettle = .1; opts.FfeStepSize = .02; opts.FfeStepSizeSettle = 1e-4; opts.FfeTrainingBlocks = 500;
opts.AnalysisNumUi = 2500 * 64 + 512;
opts.StartPhaseList = [20 96];
opts.DlevOuterInit = 36;
opts.DlevInnerInit = 12;
opts.FfeTrainingOuterRef = 36;
opts.FfeTrainingInnerRef = 12;
% Pin the supervised-reference mode with the rest of this behavioral fixture so
% the freeze regression stays independent of the option default (now 'live-dlev').
opts.FfeTrainingReferenceMode = 'fixed';
opts.FfeFreezeEnable = true;
% This fixture asserts permanent write inhibition, so pin the gate action too:
% the option default moved to 'pvt-track', which keeps writing after the
% trigger and would invalidate checks 2/5 and 3/5.
opts.FfeFreezeMode = 'freeze';
opts.FfeFreezeMinModeOccurrences = 100;
opts.FfeFreezeMinEvents = 50;
opts.FfeFreezeBandHalfWidth = 3;
opts.EyeDiagramEnable = false;
opts.SaveOutputs = false;
opts.ResultDir = outputDir;
fixtureRng = rng;
[~, frozen] = evalc('cdr_dlev_cdrffe_sslms_v3(opts)');
rng(fixtureRng);
opts.FfeFreezeEnable = false;
[~, baseline] = evalc('cdr_dlev_cdrffe_sslms_v3(opts)');

% 1/5: public result contract, dimensions, and causal monitor metadata.
required = {'FfeFrozenFlag','FfeFreezeBlock','FfeFreezeCenterUnwrapped', ...
    'FfeFreezeCenterWrapped','FfeFreezeModeOccurrences','FfeFreezeEventCount', ...
    'FfeFrozenCoefficients','FfeRawDeltaTrace','FfeProposedCoefficientTrace', ...
    'FfeAppliedDeltaTrace','FfeWriteAppliedTrace', ...
    'FfeAdaptationCalculatedTrace','FfeFrozenTrace','FfeCoeffTrace'};
assert(all(isfield(frozen, required)), 'The FFE freeze result contract is incomplete.');
n = numel(opts.StartPhaseList);
b = frozen.NumBlocks;
tapCount = numel(frozen.FfeAdaptEnableMask);
assert(isequal(size(frozen.FfeFrozenCoefficients), [n tapCount]));
assert(isequal(size(frozen.FfeCoeffTrace), [n b tapCount]));
assert(isequal(size(frozen.FfeRawDeltaTrace), [n b tapCount]));
assert(isequal(size(frozen.FfeProposedCoefficientTrace), [n b tapCount]));
assert(isequal(size(frozen.FfeAppliedDeltaTrace), [n b tapCount]));
assert(isequal(size(frozen.FfeWriteAppliedTrace), [n b]));
assert(isequal(size(frozen.FfeAdaptationCalculatedTrace), [n b]));
assert(isequal(size(frozen.FfeFrozenTrace), [n b]));
assert(numel(frozen.FfeFrozenFlag) == n && all(frozen.FfeFrozenFlag(:)));
freezeBlock = reshape(frozen.FfeFreezeBlock, 1, []);
assert(all(freezeBlock > frozen.FfeTrainingBlocks & freezeBlock < b));
assert(all(freezeBlock > 500));
assert(all(frozen.FfeFreezeModeOccurrences(:) >= 100));
assert(all(frozen.FfeFreezeEventCount(:) == 50));
assert(isequal(reshape(frozen.FfeFreezeCenterWrapped, 1, []), ...
    mod(reshape(frozen.FfeFreezeCenterUnwrapped, 1, []), frozen.SamplePerSymbol)));
for row = 1:n
    monitor = loop_monitor(100, 50, 3, frozen.FfeTrainingBlocks + 1);
    for block = 1:freezeBlock(row)
        monitor.update(baseline.UnwrappedPhaseTrace(row, block), block);
    end
    state = monitor.getState();
    assert(state.Frozen && state.FreezeBlock == freezeBlock(row));
    assert(state.CenterUnwrapped == frozen.FfeFreezeCenterUnwrapped(row));
end

% 2/5: the trigger suppresses its write and permanently latches coefficients.
for row = 1:n
    trigger = freezeBlock(row);
    assert(~any(frozen.FfeFrozenTrace(row, 1:500)));
    assert(all(frozen.FfeFrozenTrace(row, trigger:end)));
    assert(~any(frozen.FfeWriteAppliedTrace(row, trigger:end)));
    assert(all(reshape(frozen.FfeAppliedDeltaTrace(row, trigger:end, :), 1, []) == 0));
    beforeTrigger = reshape(frozen.FfeCoeffTrace(row, trigger - 1, :), 1, []);
    atTrigger = reshape(frozen.FfeCoeffTrace(row, trigger, :), 1, []);
    latched = frozen.FfeFrozenCoefficients(row, :);
    assert(isequal(atTrigger, beforeTrigger) && isequal(latched, atTrigger));
    effective = frozen.FfeCoeffTrace(row, trigger:end, :);
    expected = repmat(reshape(latched, 1, 1, tapCount), 1, b - trigger + 1, 1);
    assert(isequal(effective, expected));
end
assert(all(frozen.FfeCoeffTrace(:, :, frozen.CdrFfeMainTapIndex) == 1, 'all'));

% 3/5: adaptation remains live; proposal is current effective state plus raw delta.
calculated = logical(frozen.FfeAdaptationCalculatedTrace);
for row = 1:n
    trigger = freezeBlock(row);
    postMask = calculated(row, trigger:end);
    postRaw = frozen.FfeRawDeltaTrace(row, trigger:end, :);
    postRaw = postRaw(repmat(reshape(postMask, 1, [], 1), 1, 1, tapCount));
    assert(~isempty(postRaw) && all(isfinite(postRaw)) && any(postRaw ~= 0));
end
for row = 1:n
    blocks = find(calculated(row, 2:b-1)) + 1;
    for block = blocks
        previous = reshape(frozen.FfeCoeffTrace(row, block - 1, :), 1, []);
        raw = reshape(frozen.FfeRawDeltaTrace(row, block, :), 1, []);
        proposal = reshape(frozen.FfeProposedCoefficientTrace(row, block, :), 1, []);
        assert(isequal(proposal, previous + raw));
    end
end
assertPostBlockRecurrence(frozen);

% 4/5: enabling the monitor cannot perturb the trajectory before its write veto.
for row = 1:n
    trigger = freezeBlock(row);
    assert(isequal(frozen.PhaseCodeTrace(row, 1:trigger), ...
        baseline.PhaseCodeTrace(row, 1:trigger)));
    assert(isequal(frozen.UiSlipTrace(row, 1:trigger), ...
        baseline.UiSlipTrace(row, 1:trigger)));
    assert(isequal(frozen.DlevInnerTrace(row, 1:trigger), ...
        baseline.DlevInnerTrace(row, 1:trigger)));
    assert(isequal(frozen.DlevOuterTrace(row, 1:trigger), ...
        baseline.DlevOuterTrace(row, 1:trigger)));
    assert(isequal(frozen.FfeCoeffTrace(row, 1:trigger-1, :), ...
        baseline.FfeCoeffTrace(row, 1:trigger-1, :)));
end
assert(~any(baseline.FfeFrozenFlag(:)) && ~any(baseline.FfeFrozenTrace(:)));
assert(all(isnan(baseline.FfeFreezeCenterUnwrapped(:))));
baseCalc3 = repmat(logical(baseline.FfeAdaptationCalculatedTrace), 1, 1, tapCount);
assert(isequal(baseline.FfeRawDeltaTrace(baseCalc3), ...
    baseline.FfeAppliedDeltaTrace(baseCalc3)));

% 5/5: freeze is local to FFE writes, and SaveOutputs=false has no side effects.
for row = 1:n
    tail = freezeBlock(row):b;
    assert(any(diff(frozen.UnwrappedPhaseTrace(row, tail)) ~= 0));
end
assert(~isfolder(outputDir) && ~isfile(frozen.ResultMatPath));
fprintf('test_cdr_ffe_freeze_integration passed 5 / 5 checks.\n');
end

function assertPostBlockRecurrence(result)
[n, b, tapCount] = size(result.FfeCoeffTrace);
for row = 1:n
    for block = 2:b
        previous = reshape(result.FfeCoeffTrace(row, block - 1, :), 1, tapCount);
        applied = reshape(result.FfeAppliedDeltaTrace(row, block, :), 1, tapCount);
        current = reshape(result.FfeCoeffTrace(row, block, :), 1, tapCount);
        assert(isequal(current, previous + applied));
    end
end
end

function restoreEnvironment(oldPath, oldRng, outputDir)
path(oldPath);
rng(oldRng);
if isfolder(outputDir)
    rmdir(outputDir, 's');
end
end
