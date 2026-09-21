function [freezeEye, finalEye, eyeMeta] = build_cdr_ffe_eye_pair(ctleSegment, info, uiRequested)
%BUILD_CDR_FFE_EYE_PAIR Select freeze and final fixed-tap eye windows.
%   [FREEZEEYE, FINALEYE, EYEMETA] = BUILD_CDR_FFE_EYE_PAIR(CTLESEGMENT,
%   INFO, UIREQUESTED) selects zero-based UI windows from the cached CTLE
%   segment, then delegates all ADC, FFE, and density work to
%   BUILD_CDR_FFE_EYE.
%
%   The freeze window begins at the first block after INFO.FreezeBlock; the
%   trigger block is never included as post-freeze data. The final window is
%   the last continuous interval ending at SimulationEndUiExclusive. Neither
%   window is phase shifted or recentered. When frozen taps are used for a
%   final window that reaches back before freeze, the result is an offline
%   fixed-coefficient snapshot of that data, not a replay of time-varying taps.

validateInputs(ctleSegment, info, uiRequested);
sps = double(info.SamplesPerUi);
numBlocks = double(info.NumBlocks);
blockUi = double(info.AdcBlockUi);
baseUi = double(info.BaseUi);
analysisStartUi = double(info.AnalysisStartUi);
preTapCount = double(info.PreTapCount);
uiRequested = double(uiRequested);
slip = reshape(double(info.UiSlipTrace), 1, []);
sampledFirstUi = baseUi + (0:(numBlocks - 1)) * blockUi + slip;
simulationEndUiExclusive = sampledFirstUi(end) + blockUi;
completeSegmentUi = floor(numel(ctleSegment) / sps);

freezeEye = invalidEye('Freeze eye unavailable.');
finalEye = invalidEye('Final eye unavailable.');
eyeMeta = initialMetadata(info, uiRequested, simulationEndUiExclusive);

if ~info.Frozen
    freezeEye = invalidEye('Freeze eye unavailable: FFE coefficients were not frozen.');
elseif double(info.FreezeBlock) >= numBlocks
    freezeEye = invalidEye(['Freeze eye unavailable: freeze occurred in the final block, ', ...
        'so no post-freeze block exists.']);
else
    freezeBlock = double(info.FreezeBlock);
    freezeStartBlock = freezeBlock + 1;
    freezeStartUi = sampledFirstUi(freezeStartBlock);
    coefficients = reshape(double(info.FrozenCoefficients), 1, []);
    postTapCount = numel(coefficients) - preTapCount - 1;
    cachedRightExclusive = completeSegmentUi - preTapCount;
    availableUi = min([simulationEndUiExclusive - freezeStartUi, ...
        cachedRightExclusive - freezeStartUi]);
    if freezeStartUi < postTapCount
        freezeEye = invalidEye(sprintf(['Freeze eye unavailable: start UI %d lacks the ', ...
            'required %d-UI post-tap left margin.'], freezeStartUi, postTapCount));
    elseif availableUi < 2
        freezeEye = invalidEye(sprintf(['Freeze eye unavailable: only %d complete ', ...
            'post-freeze UI are available.'], max(0, availableUi)));
    else
        freezeUiUsed = min(uiRequested, availableUi);
        freezeEye = build_cdr_ffe_eye(ctleSegment, freezeStartUi, freezeUiUsed, ...
            sps, coefficients, preTapCount, info.AdcBits, info.AdcRange);
        freezeEye = annotateEye(freezeEye, uiRequested, analysisStartUi, ...
            info.FreezeCenterCode, true, 'Frozen coefficient snapshot', ...
            'Coefficients latched at the freeze event are applied offline.');
        freezeEye.StartBlock = freezeStartBlock;
        eyeMeta.UiCountUsedFreeze = freezeUiUsed;
        eyeMeta.FreezeStartBlock = freezeStartBlock;
        eyeMeta.FreezeStartUi = freezeStartUi;
        eyeMeta.FreezeGlobalStartUi = analysisStartUi + freezeStartUi;
    end
end

if info.Frozen
    finalCoefficients = reshape(double(info.FrozenCoefficients), 1, []);
    finalUsesFrozenTaps = true;
    finalLabel = 'Frozen coefficient snapshot on final data window';
    finalReason = ['The frozen coefficients are applied as one fixed offline snapshot; ', ...
        'any pre-freeze data in this window is not replayed with time-varying taps.'];
else
    finalCoefficients = reshape(double(info.FinalCoefficients), 1, []);
    finalUsesFrozenTaps = false;
    finalLabel = 'Final coefficient snapshot (FFE not frozen)';
    finalReason = 'No freeze occurred; final coefficients are applied as one fixed offline snapshot.';
end
postTapCount = numel(finalCoefficients) - preTapCount - 1;
firstRunUi = sampledFirstUi(1);
wholeRunUi = simulationEndUiExclusive - firstRunUi;
finalUiUsed = min(uiRequested, wholeRunUi);
finalStartUi = max(firstRunUi, simulationEndUiExclusive - uiRequested);
cachedRightExclusive = completeSegmentUi - preTapCount;
if finalUiUsed < 2
    finalEye = invalidEye(sprintf('Final eye unavailable: only %d complete run UI are available.', ...
        max(0, finalUiUsed)));
elseif finalStartUi < postTapCount
    finalEye = invalidEye(sprintf(['Final eye unavailable: start UI %d lacks the ', ...
        'required %d-UI post-tap left margin.'], finalStartUi, postTapCount));
elseif cachedRightExclusive < simulationEndUiExclusive
    finalEye = invalidEye(sprintf(['Final eye unavailable: cached right margin ends at UI %d, ', ...
        'before the simulation endpoint UI %d.'], cachedRightExclusive, simulationEndUiExclusive));
else
    finalEye = build_cdr_ffe_eye(ctleSegment, finalStartUi, finalUiUsed, ...
        sps, finalCoefficients, preTapCount, info.AdcBits, info.AdcRange);
    finalEye = annotateEye(finalEye, uiRequested, analysisStartUi, ...
        info.FinalLockCode, finalUsesFrozenTaps, finalLabel, finalReason);
    eyeMeta.UiCountUsedFinal = finalUiUsed;
    eyeMeta.FinalStartUi = finalStartUi;
    eyeMeta.FinalGlobalStartUi = analysisStartUi + finalStartUi;
end
end

function eye = annotateEye(eye, requested, analysisStartUi, markerCode, usesFrozen, label, reason)
eye.GlobalStartUi = analysisStartUi + eye.StartUi;
eye.MarkerCode = double(markerCode);
eye.UsesFrozenTaps = logical(usesFrozen);
eye.RequestedUiCount = requested;
eye.Truncated = eye.UiCountUsed < requested;
if eye.Truncated
    eye.TruncationMessage = sprintf('Requested %d UI; only %d contiguous UI were available.', ...
        requested, eye.UiCountUsed);
else
    eye.TruncationMessage = '';
end
eye.FixedTapLabel = label;
eye.FixedTapReason = reason;
end

function eye = invalidEye(reason)
eye = struct('Valid', false, 'Reason', reason);
end

function meta = initialMetadata(info, requested, simulationEnd)
meta = struct();
meta.RequestedUiCount = requested;
meta.UiCountUsedFreeze = 0;
meta.UiCountUsedFinal = 0;
meta.SelectedStartPhase = double(info.SelectedStartPhase);
meta.FreezeBlock = double(info.FreezeBlock);
meta.FreezeStartBlock = NaN;
meta.FreezeStartUi = NaN;
meta.FinalStartUi = NaN;
meta.FreezeGlobalStartUi = NaN;
meta.FinalGlobalStartUi = NaN;
meta.FreezeCenterCode = double(info.FreezeCenterCode);
meta.FinalLockCode = double(info.FinalLockCode);
meta.UsesFrozenTaps = logical(info.Frozen);
meta.SimulationEndUiExclusive = simulationEnd;
end

function validateInputs(ctleSegment, info, uiRequested)
if ~isnumeric(ctleSegment) || ~isreal(ctleSegment) || ~isvector(ctleSegment) || ...
        isempty(ctleSegment) || any(~isfinite(ctleSegment(:)))
    error('build_cdr_ffe_eye_pair:InvalidCtLeSegment', ...
        'ctleSegment must be a nonempty finite real numeric vector.');
end
if ~isstruct(info) || ~isscalar(info)
    error('build_cdr_ffe_eye_pair:InvalidInfo', 'info must be a scalar struct.');
end
required = {'SelectedStartPhase', 'SamplesPerUi', 'NumBlocks', 'AdcBlockUi', ...
    'BaseUi', 'AnalysisStartUi', 'UiSlipTrace', 'PreTapCount', 'AdcBits', ...
    'AdcRange', 'FinalCoefficients', 'Frozen', 'FreezeBlock', ...
    'FrozenCoefficients', 'FreezeCenterCode', 'FinalLockCode'};
for index = 1:numel(required)
    if ~isfield(info, required{index})
        error('build_cdr_ffe_eye_pair:MissingInfoField', ...
            'info.%s is required.', required{index});
    end
end
validateInteger(uiRequested, 2, 'uiRequested');
validateInteger(info.SelectedStartPhase, 0, 'info.SelectedStartPhase');
validateInteger(info.SamplesPerUi, 1, 'info.SamplesPerUi');
validateInteger(info.NumBlocks, 1, 'info.NumBlocks');
validateInteger(info.AdcBlockUi, 1, 'info.AdcBlockUi');
validateInteger(info.BaseUi, 0, 'info.BaseUi');
validateInteger(info.AnalysisStartUi, 0, 'info.AnalysisStartUi');
validateInteger(info.PreTapCount, 0, 'info.PreTapCount');
validateInteger(info.AdcBits, 1, 'info.AdcBits');
if double(info.AdcBits) > 24
    error('build_cdr_ffe_eye_pair:InvalidInfoField', 'info.AdcBits must be no greater than 24.');
end
if ~isnumeric(info.UiSlipTrace) || ~isreal(info.UiSlipTrace) || ...
        ~isrow(info.UiSlipTrace) || numel(info.UiSlipTrace) ~= double(info.NumBlocks) || ...
        any(~isfinite(info.UiSlipTrace)) || any(double(info.UiSlipTrace) ~= fix(double(info.UiSlipTrace)))
    error('build_cdr_ffe_eye_pair:InvalidInfoField', ...
        'info.UiSlipTrace must be a finite integer row with info.NumBlocks entries.');
end
sampled = double(info.BaseUi) + (0:(double(info.NumBlocks) - 1)) * ...
    double(info.AdcBlockUi) + double(info.UiSlipTrace);
if any(sampled < 0) || any(diff(sampled) <= 0)
    error('build_cdr_ffe_eye_pair:InvalidInfoField', ...
        'info.UiSlipTrace must produce nonnegative, strictly increasing sampled block starts.');
end
validateCoefficients(info.FinalCoefficients, info.PreTapCount, 'info.FinalCoefficients');
if ~(islogical(info.Frozen) && isscalar(info.Frozen))
    error('build_cdr_ffe_eye_pair:InvalidInfoField', 'info.Frozen must be a logical scalar.');
end
if info.Frozen
    validateInteger(info.FreezeBlock, 1, 'info.FreezeBlock');
    if double(info.FreezeBlock) > double(info.NumBlocks)
        error('build_cdr_ffe_eye_pair:InvalidInfoField', ...
            'info.FreezeBlock cannot exceed info.NumBlocks.');
    end
    validateCoefficients(info.FrozenCoefficients, info.PreTapCount, 'info.FrozenCoefficients');
elseif ~isnumeric(info.FreezeBlock) || ~isreal(info.FreezeBlock) || ...
        ~isscalar(info.FreezeBlock) || ~isnan(info.FreezeBlock)
    error('build_cdr_ffe_eye_pair:InvalidInfoField', ...
        'info.FreezeBlock must be NaN when info.Frozen is false.');
end
if ~isnumeric(info.AdcRange) || ~isreal(info.AdcRange) || numel(info.AdcRange) ~= 2 || ...
        any(~isfinite(info.AdcRange(:))) || double(info.AdcRange(2)) <= double(info.AdcRange(1))
    error('build_cdr_ffe_eye_pair:InvalidInfoField', ...
        'info.AdcRange must be a finite increasing two-element numeric vector.');
end
validateFiniteOrNan(info.FreezeCenterCode, 'info.FreezeCenterCode');
validateFiniteOrNan(info.FinalLockCode, 'info.FinalLockCode');
end

function validateCoefficients(value, preTapCount, name)
if ~isnumeric(value) || ~isreal(value) || ~isvector(value) || isempty(value) || any(~isfinite(value(:))) || ...
        double(preTapCount) >= numel(value) || double(value(double(preTapCount) + 1)) ~= 1
    error('build_cdr_ffe_eye_pair:InvalidInfoField', ...
        '%s must be finite with main tap one at info.PreTapCount+1.', name);
end
end

function validateInteger(value, minimum, name)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value) || ...
        double(value) ~= fix(double(value)) || double(value) < minimum
    error('build_cdr_ffe_eye_pair:InvalidInfoField', ...
        '%s must be an integer scalar greater than or equal to %d.', name, minimum);
end
end

function validateFiniteOrNan(value, name)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~(isfinite(value) || isnan(value))
    error('build_cdr_ffe_eye_pair:InvalidInfoField', ...
        '%s must be a finite scalar or NaN.', name);
end
end
