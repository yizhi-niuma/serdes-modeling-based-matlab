function test_build_cdr_ffe_eye_pair
%TEST_BUILD_CDR_FFE_EYE_PAIR Targeted freeze/final window-selection tests.

thisFile = mfilename('fullpath');
repoRoot = fileparts(fileparts(fileparts(thisFile)));
addpath(fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe'), '-begin');

checkExactFreezeAndFinalWindows();
checkLateFreezeTruncation();
checkUnavailableFreezeCases();
checkShortRunAndCustomRequest();
checkSlipAdjustedPhysicalFreezeBounds();
checkRightMarginGuard();

fprintf('test_build_cdr_ffe_eye_pair passed 6 / 6 checks.\n');
end

function checkExactFreezeAndFinalWindows()
info = fixtureInfo(40);
info.FreezeBlock = 5;
info.FreezeCenterCode = 17;
info.FinalLockCode = 91;
info.UiSlipTrace = repmat([0 -2 1 -1], 1, 10);
requested = 256;
wave = fixtureWaveform(info);
[freezeEye, finalEye, meta] = build_cdr_ffe_eye_pair(wave, info, requested);
starts = sampledStarts(info);
expectedFreezeStart = starts(info.FreezeBlock + 1);
expectedEnd = starts(end) + info.AdcBlockUi;
expectedFinalStart = expectedEnd - requested;
directFreeze = build_cdr_ffe_eye(wave, expectedFreezeStart, requested, ...
    info.SamplesPerUi, info.FrozenCoefficients, info.PreTapCount, info.AdcBits, info.AdcRange);
directFinal = build_cdr_ffe_eye(wave, expectedFinalStart, requested, ...
    info.SamplesPerUi, info.FrozenCoefficients, info.PreTapCount, info.AdcBits, info.AdcRange);

assert(freezeEye.Valid && finalEye.Valid);
assert(freezeEye.StartBlock == info.FreezeBlock + 1); % never the trigger block
assert(freezeEye.StartUi == expectedFreezeStart);
assert(finalEye.StartUi == expectedFinalStart);
assert(isequal(freezeEye.OutputCodeGrid, directFreeze.OutputCodeGrid));
assert(isequal(finalEye.OutputCodeGrid, directFinal.OutputCodeGrid));
assert(freezeEye.MarkerCode == 17 && finalEye.MarkerCode == 91);
assert(freezeEye.UsesFrozenTaps && finalEye.UsesFrozenTaps);
assert(~freezeEye.Truncated && ~finalEye.Truncated);
assert(meta.RequestedUiCount == requested);
assert(meta.UiCountUsedFreeze == requested && meta.UiCountUsedFinal == requested);
assert(meta.FreezeStartBlock == 6 && meta.FreezeStartUi == expectedFreezeStart);
assert(meta.FinalStartUi == expectedFinalStart);
assert(meta.FreezeGlobalStartUi == info.AnalysisStartUi + expectedFreezeStart);
assert(meta.FinalGlobalStartUi == info.AnalysisStartUi + expectedFinalStart);
assert(meta.SimulationEndUiExclusive == expectedEnd);
assert(sum(freezeEye.Density(:)) == 2 * info.SamplesPerUi * (requested - 1));
assert(sum(finalEye.Density(:)) == 2 * info.SamplesPerUi * (requested - 1));
end

function checkLateFreezeTruncation()
info = fixtureInfo(40);
info.FreezeBlock = 39;
wave = fixtureWaveform(info);
[freezeEye, finalEye, meta] = build_cdr_ffe_eye_pair(wave, info, 128);
starts = sampledStarts(info);
direct = build_cdr_ffe_eye(wave, starts(40), 64, info.SamplesPerUi, ...
    info.FrozenCoefficients, info.PreTapCount, info.AdcBits, info.AdcRange);

assert(freezeEye.Valid && finalEye.Valid);
assert(freezeEye.StartBlock == 40 && freezeEye.UiCountUsed == 64);
assert(freezeEye.Truncated && ~isempty(freezeEye.TruncationMessage));
assert(isequal(freezeEye.OutputCodeGrid, direct.OutputCodeGrid));
assert(meta.UiCountUsedFreeze == 64);
assert(sum(freezeEye.Density(:)) == 2 * info.SamplesPerUi * 63);
end

function checkUnavailableFreezeCases()
info = fixtureInfo(40);
info.Frozen = false;
info.FreezeBlock = NaN;
info.FrozenCoefficients = NaN(1, 6); % deliberately ignored
wave = fixtureWaveform(info);
[freezeEye, finalEye, meta] = build_cdr_ffe_eye_pair(wave, info, 256);
expectedStart = sampledStarts(info);
expectedStart = expectedStart(end) + info.AdcBlockUi - 256;
direct = build_cdr_ffe_eye(wave, expectedStart, 256, info.SamplesPerUi, ...
    info.FinalCoefficients, info.PreTapCount, info.AdcBits, info.AdcRange);

assert(~freezeEye.Valid && ~isempty(freezeEye.Reason));
assert(finalEye.Valid && ~finalEye.UsesFrozenTaps);
assert(isequal(finalEye.OutputCodeGrid, direct.OutputCodeGrid));
assert(contains(finalEye.FixedTapLabel, 'not frozen'));
assert(isnan(meta.FreezeStartBlock) && isnan(meta.FreezeStartUi));
assert(~meta.UsesFrozenTaps);

info = fixtureInfo(40);
info.FreezeBlock = info.NumBlocks;
wave = fixtureWaveform(info);
[freezeEye, finalEye] = build_cdr_ffe_eye_pair(wave, info, 128);
assert(~freezeEye.Valid && contains(freezeEye.Reason, 'final block'));
assert(finalEye.Valid && finalEye.UsesFrozenTaps);
end

function checkShortRunAndCustomRequest()
info = fixtureInfo(20);
info.FreezeBlock = 18;
wave = fixtureWaveform(info);
[freezeEye, finalEye, meta] = build_cdr_ffe_eye_pair(wave, info, 2048);
starts = sampledStarts(info);
wholeRun = starts(end) + info.AdcBlockUi - starts(1);

assert(freezeEye.Valid && freezeEye.UiCountUsed == 128);
assert(freezeEye.Truncated);
assert(finalEye.Valid && finalEye.UiCountUsed == wholeRun);
assert(finalEye.StartUi == starts(1) && finalEye.Truncated);
assert(meta.UiCountUsedFreeze == 128 && meta.UiCountUsedFinal == wholeRun);

info = fixtureInfo(40);
wave = fixtureWaveform(info);
[freezeEye, finalEye, meta] = build_cdr_ffe_eye_pair(wave, info, 256);
assert(freezeEye.UiCountUsed == 256 && finalEye.UiCountUsed == 256);
assert(meta.RequestedUiCount == 256);
end

function checkSlipAdjustedPhysicalFreezeBounds()
info = fixtureInfo(40);
info.FreezeBlock = info.NumBlocks - 2;
info.UiSlipTrace(end) = 1;
wave = fixtureWaveform(info);
[freezeEye, ~, meta] = build_cdr_ffe_eye_pair(wave, info, 129);

assert(freezeEye.Valid && freezeEye.UiCountUsed == 129);
assert(~freezeEye.Truncated && meta.UiCountUsedFreeze == 129);
assert(freezeEye.StartUi + freezeEye.UiCountUsed == meta.SimulationEndUiExclusive);

info.UiSlipTrace(end) = -1;
wave = fixtureWaveform(info);
[freezeEye, ~, meta] = build_cdr_ffe_eye_pair(wave, info, 129);

assert(freezeEye.Valid && freezeEye.UiCountUsed == 127);
assert(freezeEye.Truncated && meta.UiCountUsedFreeze == 127);
assert(freezeEye.StartUi + freezeEye.UiCountUsed == meta.SimulationEndUiExclusive);
end

function checkRightMarginGuard()
info = fixtureInfo(8);
wave = fixtureWaveform(info);
wave = wave(1:end - info.SamplesPerUi); % remove one required pre-tap UI
[~, finalEye, meta] = build_cdr_ffe_eye_pair(wave, info, 64);
assert(~finalEye.Valid && contains(finalEye.Reason, 'cached right margin'));
assert(meta.UiCountUsedFinal == 0 && isnan(meta.FinalStartUi));
end

function info = fixtureInfo(numBlocks)
info = struct();
info.SelectedStartPhase = 3;
info.SamplesPerUi = 8;
info.NumBlocks = numBlocks;
info.AdcBlockUi = 64;
info.BaseUi = 8;
info.AnalysisStartUi = 1000;
info.UiSlipTrace = zeros(1, numBlocks);
info.PreTapCount = 2;
info.AdcBits = 7;
info.AdcRange = [-1 1];
info.FinalCoefficients = [0.2 0 1 -0.2 0.05 0];
info.Frozen = true;
info.FreezeBlock = min(4, numBlocks - 1);
info.FrozenCoefficients = [0.1 -0.1 1 0.1 0 0];
info.FreezeCenterCode = 13;
info.FinalLockCode = 77;
end

function starts = sampledStarts(info)
starts = info.BaseUi + (0:(info.NumBlocks - 1)) * info.AdcBlockUi + info.UiSlipTrace;
end

function wave = fixtureWaveform(info)
endUi = sampledStarts(info);
endUi = endUi(end) + info.AdcBlockUi;
totalUi = endUi + info.PreTapCount;
t = (0:(totalUi * info.SamplesPerUi - 1)) / info.SamplesPerUi;
symbol = mod(0:(totalUi - 1), 4) - 1.5;
wave = 0.42 * repelem(symbol / 1.5, info.SamplesPerUi) + ...
    0.07 * sin(2 * pi * 0.43 * t + 0.19) + 0.03 * cos(2 * pi * t);
end
