function [eyes, setMeta] = build_ppm_eye_set(ctleSegment, info, anchorBlocks, uiRequested)
%BUILD_PPM_EYE_SET Select anchored and final fixed-tap eye windows.
%   [EYES, SETMETA] = BUILD_PPM_EYE_SET(CTLESEGMENT, INFO, ANCHORBLOCKS,
%   UIREQUESTED) reconstructs frequency-offset block addresses in the cached
%   CTLE segment, selects zero-based UI windows, and delegates all ADC, FFE,
%   and density work to BUILD_CDR_FFE_EYE.
%
%   ANCHORBLOCKS is a numeric vector with one entry per requested anchored
%   window. A finite entry selects the window beginning at that block's
%   reconstructed start UI. A NaN entry produces an invalid eye with an
%   explanatory Reason. EYES has one additional element at the end for the
%   final continuous interval ending at SimulationEndUiExclusive.
%
%   INFO.AnchorLabels supplies one label per anchor. Labels identify the
%   fixed-tap snapshots in the eye annotations and SETMETA; they do not
%   affect window selection or eye physics. All other INFO fields describe
%   the saved run, address traces, ADC, and per-block FFE coefficients.
%
%   Every finite anchor uses its own block's coefficient row. The final eye
%   uses the final-block row. These are offline fixed-coefficient snapshots,
%   not a replay of the time-varying taps used during the original run.
%   Integer sample-domain drift is included before each block address is
%   divided into its zero-based UI index and sub-UI code.
%
%   Sampling markers are computed from unwrapped tracked-eye phase before
%   wrapping. Consequently MarkerSpanCode remains meaningful when marker
%   codes cross the zero/SamplesPerUi boundary.

validateInputs(ctleSegment, info, anchorBlocks, uiRequested);
sps = double(info.SamplesPerUi);
numBlocks = double(info.NumBlocks);
blockUi = double(info.AdcBlockUi);
baseUi = double(info.BaseUi);
analysisStartUi = double(info.AnalysisStartUi);
preTapCount = double(info.PreTapCount);
uiRequested = double(uiRequested);
anchorBlocks = reshape(double(anchorBlocks), 1, []);
anchorLabels = normalizeLabels(info.AnchorLabels);
phaseCode = reshape(double(info.PhaseCodeTrace), 1, []);
slip = reshape(double(info.UiSlipTrace), 1, []);
drift = reshape(double(info.DriftSampleTrace), 1, []);
eyePhase = reshape(double(info.EyePhaseUnwrappedTrace), 1, []);
coefficientTrace = double(info.FfeCoeffTrace);

absSample0 = (baseUi + (0:(numBlocks - 1)) * blockUi + slip) * sps + ...
    phaseCode + drift;
blockStartUi = floor(absSample0 / sps);
subUiCode = mod(absSample0, sps);
trackedSubUiCode = mod(eyePhase, sps);
mismatch = subUiCode ~= trackedSubUiCode;
if any(mismatch)
    badBlocks = find(mismatch);
    [~, worstOffset] = max(abs(subUiCode(mismatch) - ...
        trackedSubUiCode(mismatch)));
    worstBlock = badBlocks(worstOffset);
    error('build_ppm_eye_set:InconsistentAddressTrace', ...
        ['Block %d has reconstructed sub-UI code %.17g but ', ...
        'EyePhaseUnwrappedTrace gives %.17g.'], ...
        worstBlock, subUiCode(worstBlock), trackedSubUiCode(worstBlock));
end

simulationEndUiExclusive = blockStartUi(end) + blockUi;
completeSegmentUi = floor(numel(ctleSegment) / sps);
finalCoefficients = reshape(coefficientTrace(end, :), 1, []);
eyeCount = numel(anchorBlocks) + 1;
eyeCells = cell(1, eyeCount);
coefficientCells = cell(1, eyeCount);

for anchorIndex = 1:numel(anchorBlocks)
    anchorBlock = anchorBlocks(anchorIndex);
    anchorLabel = anchorLabels{anchorIndex};
    fixedLabel = sprintf('%s coefficient snapshot', anchorLabel);
    fixedReason = sprintf(['The %s coefficients are applied as one fixed ', ...
        'offline snapshot; this window is not replayed with time-varying taps.'], ...
        anchorLabel);
    if isnan(anchorBlock)
        reason = sprintf(['%s eye unavailable: anchor block is NaN, so no ', ...
            'tracked-eye anchor block was recorded.'], anchorLabel);
        eyeCells{anchorIndex} = invalidEye(reason, uiRequested, fixedLabel, ...
            fixedReason, anchorLabel, NaN, NaN, NaN, NaN);
        coefficientCells{anchorIndex} = NaN;
        continue;
    end

    anchorStartUi = blockStartUi(anchorBlock);
    anchorCoefficients = reshape(coefficientTrace(anchorBlock, :), 1, []);
    postTapCount = numel(anchorCoefficients) - preTapCount - 1;
    cachedRightExclusive = completeSegmentUi - preTapCount;
    availableUi = min(simulationEndUiExclusive - anchorStartUi, ...
        cachedRightExclusive - anchorStartUi);
    coefficientCells{anchorIndex} = anchorCoefficients;
    if anchorStartUi < postTapCount
        reason = sprintf(['%s eye unavailable: start UI %d lacks the ', ...
            'required %d-UI post-tap left margin.'], anchorLabel, ...
            anchorStartUi, postTapCount);
        eyeCells{anchorIndex} = invalidEye(reason, uiRequested, fixedLabel, ...
            fixedReason, anchorLabel, anchorBlock, anchorStartUi, ...
            analysisStartUi + anchorStartUi, anchorCoefficients);
    elseif availableUi < 2
        reason = sprintf(['%s eye unavailable: only %d complete UI are ', ...
            'available from the anchor block.'], anchorLabel, max(0, availableUi));
        eyeCells{anchorIndex} = invalidEye(reason, uiRequested, fixedLabel, ...
            fixedReason, anchorLabel, anchorBlock, anchorStartUi, ...
            analysisStartUi + anchorStartUi, anchorCoefficients);
    else
        anchorUiUsed = min(uiRequested, availableUi);
        eye = build_cdr_ffe_eye(ctleSegment, anchorStartUi, anchorUiUsed, ...
            sps, anchorCoefficients, preTapCount, info.AdcBits, info.AdcRange);
        eyeCells{anchorIndex} = annotateEye(eye, uiRequested, analysisStartUi, ...
            blockStartUi, eyePhase, fixedLabel, fixedReason, anchorLabel, ...
            anchorBlock);
    end
end

finalLabel = 'final';
finalFixedLabel = 'Final-block coefficient snapshot on final data window';
finalFixedReason = ['The final-block coefficients are applied as one fixed ', ...
    'offline snapshot; this window is not replayed with time-varying taps.'];
firstRunUi = blockStartUi(1);
wholeRunUi = simulationEndUiExclusive - firstRunUi;
finalUiUsed = min(uiRequested, wholeRunUi);
finalStartUi = max(firstRunUi, simulationEndUiExclusive - uiRequested);
postTapCount = numel(finalCoefficients) - preTapCount - 1;
cachedRightExclusive = completeSegmentUi - preTapCount;
coefficientCells{end} = finalCoefficients;
if finalUiUsed < 2
    reason = sprintf('Final eye unavailable: only %d complete run UI are available.', ...
        max(0, finalUiUsed));
    eyeCells{end} = invalidEye(reason, uiRequested, finalFixedLabel, ...
        finalFixedReason, finalLabel, NaN, finalStartUi, ...
        analysisStartUi + finalStartUi, finalCoefficients);
elseif finalStartUi < postTapCount
    reason = sprintf(['Final eye unavailable: start UI %d lacks the ', ...
        'required %d-UI post-tap left margin.'], finalStartUi, postTapCount);
    eyeCells{end} = invalidEye(reason, uiRequested, finalFixedLabel, ...
        finalFixedReason, finalLabel, NaN, finalStartUi, ...
        analysisStartUi + finalStartUi, finalCoefficients);
elseif cachedRightExclusive < simulationEndUiExclusive
    reason = sprintf(['Final eye unavailable: cached right margin ends at UI %d, ', ...
        'before the simulation endpoint UI %d.'], cachedRightExclusive, ...
        simulationEndUiExclusive);
    eyeCells{end} = invalidEye(reason, uiRequested, finalFixedLabel, ...
        finalFixedReason, finalLabel, NaN, finalStartUi, ...
        analysisStartUi + finalStartUi, finalCoefficients);
else
    eye = build_cdr_ffe_eye(ctleSegment, finalStartUi, finalUiUsed, ...
        sps, finalCoefficients, preTapCount, info.AdcBits, info.AdcRange);
    eyeCells{end} = annotateEye(eye, uiRequested, analysisStartUi, ...
        blockStartUi, eyePhase, finalFixedLabel, finalFixedReason, ...
        finalLabel, NaN);
end

eyes = [eyeCells{:}];
labels = [anchorLabels, {finalLabel}];
setMeta = buildMetadata(info, uiRequested, simulationEndUiExclusive, ...
    numBlocks, anchorBlocks, anchorLabels, eyes, coefficientCells, labels);
end

function eye = annotateEye(eye, requested, analysisStartUi, blockStartUi, ...
        eyePhase, label, reason, anchorLabel, anchorBlock)
windowBlocks = find(blockStartUi >= eye.StartUi & ...
    blockStartUi < eye.StartUi + eye.UiCountUsed);
assert(~isempty(windowBlocks), 'build_ppm_eye_set:EmptyMarkerWindow', ...
    'A valid eye window must contain at least one sampled block start.');
windowPhase = eyePhase(windowBlocks);
relativePhase = windowPhase - windowPhase(1);
trackedMean = windowPhase(1) + mean(relativePhase);
eye.GlobalStartUi = analysisStartUi + eye.StartUi;
eye.StartBlock = windowBlocks(1);
eye.MarkerCode = mod(trackedMean, eye.SamplesPerUi);
eye.MarkerMinCode = mod(windowPhase(1) + min(relativePhase), ...
    eye.SamplesPerUi);
eye.MarkerMaxCode = mod(windowPhase(1) + max(relativePhase), ...
    eye.SamplesPerUi);
eye.MarkerSpanCode = max(relativePhase) - min(relativePhase);
eye.MarkerBlocks = [windowBlocks(1), windowBlocks(end)];
eye.TrackedEyePhaseMean = trackedMean;
eye.RequestedUiCount = requested;
eye.Truncated = eye.UiCountUsed < requested;
if eye.Truncated
    eye.TruncationMessage = sprintf( ...
        'Requested %d UI; only %d contiguous UI were available.', ...
        requested, eye.UiCountUsed);
else
    eye.TruncationMessage = '';
end
eye.FixedTapLabel = label;
eye.FixedTapReason = reason;
eye.AnchorLabel = anchorLabel;
eye.AnchorBlock = anchorBlock;
end

function eye = invalidEye(reason, requested, fixedLabel, fixedReason, ...
        anchorLabel, anchorBlock, startUi, globalStartUi, coefficients)
eye = struct();
eye.Valid = false;
eye.Reason = reason;
eye.OutputCodeGrid = [];
eye.UiCountUsed = 0;
eye.StartUi = startUi;
eye.Coefficients = coefficients;
eye.SamplesPerUi = [];
eye.PhaseUi = [];
eye.CodeBinCenters = [];
eye.CodeBinEdges = [];
eye.Density = [];
eye.TraceCount = 0;
eye.Minimum = NaN;
eye.Maximum = NaN;
eye.GlobalStartUi = globalStartUi;
eye.StartBlock = NaN;
eye.MarkerCode = NaN;
eye.MarkerMinCode = NaN;
eye.MarkerMaxCode = NaN;
eye.MarkerSpanCode = NaN;
eye.MarkerBlocks = [NaN NaN];
eye.TrackedEyePhaseMean = NaN;
eye.RequestedUiCount = requested;
eye.Truncated = false;
eye.TruncationMessage = '';
eye.FixedTapLabel = fixedLabel;
eye.FixedTapReason = fixedReason;
eye.AnchorLabel = anchorLabel;
eye.AnchorBlock = anchorBlock;
end

function meta = buildMetadata(info, requested, simulationEnd, numBlocks, ...
        anchorBlocks, anchorLabels, eyes, coefficients, labels)
eyeCount = numel(eyes);
meta = struct();
meta.RequestedUiCount = requested;
meta.NumBlocks = numBlocks;
meta.SelectedStartPhase = double(info.SelectedStartPhase);
meta.FreqOffsetPpm = double(info.FreqOffsetPpm);
meta.SimulationEndUiExclusive = simulationEnd;
meta.AnchorBlocks = anchorBlocks;
meta.AnchorLabels = anchorLabels;
meta.UiCountUsed = reshape([eyes.UiCountUsed], 1, eyeCount);
meta.StartUi = reshape([eyes.StartUi], 1, eyeCount);
meta.GlobalStartUi = reshape([eyes.GlobalStartUi], 1, eyeCount);
meta.MarkerCode = reshape([eyes.MarkerCode], 1, eyeCount);
meta.MarkerSpanCode = reshape([eyes.MarkerSpanCode], 1, eyeCount);
meta.Valid = reshape(logical([eyes.Valid]), 1, eyeCount);
meta.Coefficients = reshape(coefficients, 1, eyeCount);
meta.Labels = reshape(labels, 1, eyeCount);
end

function labels = normalizeLabels(value)
if isstring(value)
    labels = cellstr(reshape(value, 1, []));
else
    labels = reshape(value, 1, []);
end
end

function validateInputs(ctleSegment, info, anchorBlocks, uiRequested)
if ~isnumeric(ctleSegment) || ~isreal(ctleSegment) || ...
        ~isvector(ctleSegment) || isempty(ctleSegment) || ...
        any(~isfinite(ctleSegment(:)))
    error('build_ppm_eye_set:InvalidCtLeSegment', ...
        'ctleSegment must be a nonempty finite real numeric vector.');
end
if ~isstruct(info) || ~isscalar(info)
    error('build_ppm_eye_set:InvalidInfo', 'info must be a scalar struct.');
end
required = {'SamplesPerUi', 'NumBlocks', 'AdcBlockUi', 'BaseUi', ...
    'AnalysisStartUi', 'PreTapCount', 'AdcBits', 'AdcRange', ...
    'SelectedStartPhase', 'FreqOffsetPpm', 'AnchorLabels', ...
    'PhaseCodeTrace', 'UiSlipTrace', 'DriftSampleTrace', ...
    'EyePhaseUnwrappedTrace', 'FfeCoeffTrace'};
for index = 1:numel(required)
    if ~isfield(info, required{index})
        error('build_ppm_eye_set:MissingInfoField', ...
            'info.%s is required.', required{index});
    end
end
validateInteger(uiRequested, 2, 'uiRequested');
validateInteger(info.SamplesPerUi, 1, 'info.SamplesPerUi');
validateInteger(info.NumBlocks, 1, 'info.NumBlocks');
validateInteger(info.AdcBlockUi, 1, 'info.AdcBlockUi');
validateInteger(info.BaseUi, 0, 'info.BaseUi');
validateInteger(info.AnalysisStartUi, 0, 'info.AnalysisStartUi');
validateInteger(info.PreTapCount, 0, 'info.PreTapCount');
validateInteger(info.AdcBits, 1, 'info.AdcBits');
validateInteger(info.SelectedStartPhase, 0, 'info.SelectedStartPhase');
if double(info.AdcBits) > 24
    error('build_ppm_eye_set:InvalidInfoField', ...
        'info.AdcBits must be no greater than 24.');
end
if ~isnumeric(info.FreqOffsetPpm) || ~isreal(info.FreqOffsetPpm) || ...
        ~isscalar(info.FreqOffsetPpm) || ~isfinite(info.FreqOffsetPpm)
    error('build_ppm_eye_set:InvalidInfoField', ...
        'info.FreqOffsetPpm must be a finite real numeric scalar.');
end
numBlocks = double(info.NumBlocks);
sps = double(info.SamplesPerUi);
validateAnchorBlocks(anchorBlocks, numBlocks);
validateAnchorLabels(info.AnchorLabels, numel(anchorBlocks));
validateTrace(info.PhaseCodeTrace, numBlocks, true, 'info.PhaseCodeTrace');
phaseCode = double(info.PhaseCodeTrace);
if any(phaseCode < 0) || any(phaseCode >= sps)
    error('build_ppm_eye_set:InvalidInfoField', ...
        'info.PhaseCodeTrace entries must be in [0, info.SamplesPerUi-1].');
end
validateTrace(info.UiSlipTrace, numBlocks, true, 'info.UiSlipTrace');
validateTrace(info.DriftSampleTrace, numBlocks, true, ...
    'info.DriftSampleTrace');
validateTrace(info.EyePhaseUnwrappedTrace, numBlocks, false, ...
    'info.EyePhaseUnwrappedTrace');
if ~isnumeric(info.FfeCoeffTrace) || ~isreal(info.FfeCoeffTrace) || ...
        ~ismatrix(info.FfeCoeffTrace) || ...
        size(info.FfeCoeffTrace, 1) ~= numBlocks || ...
        size(info.FfeCoeffTrace, 2) < 1 || ...
        any(~isfinite(info.FfeCoeffTrace(:)))
    error('build_ppm_eye_set:InvalidInfoField', ...
        ['info.FfeCoeffTrace must be a finite info.NumBlocks-by-numTaps ', ...
        'real numeric matrix.']);
end
preTapCount = double(info.PreTapCount);
if preTapCount >= size(info.FfeCoeffTrace, 2) || ...
        any(double(info.FfeCoeffTrace(:, preTapCount + 1)) ~= 1)
    error('build_ppm_eye_set:InvalidInfoField', ...
        ['info.FfeCoeffTrace must have main tap one at ', ...
        'info.PreTapCount+1 in every row.']);
end
if ~isnumeric(info.AdcRange) || ~isreal(info.AdcRange) || ...
        ~isvector(info.AdcRange) || numel(info.AdcRange) ~= 2 || ...
        any(~isfinite(info.AdcRange(:))) || ...
        double(info.AdcRange(2)) <= double(info.AdcRange(1))
    error('build_ppm_eye_set:InvalidInfoField', ...
        'info.AdcRange must be a finite increasing two-element numeric vector.');
end
absSample0 = (double(info.BaseUi) + (0:(numBlocks - 1)) * ...
    double(info.AdcBlockUi) + double(info.UiSlipTrace)) * sps + ...
    double(info.PhaseCodeTrace) + double(info.DriftSampleTrace);
blockStartUi = floor(absSample0 / sps);
if any(~isfinite(absSample0)) || any(blockStartUi < 0) || ...
        any(diff(blockStartUi) <= 0)
    error('build_ppm_eye_set:InvalidInfoField', ...
        ['info address traces must produce finite, nonnegative, strictly ', ...
        'increasing blockStartUi values.']);
end
end

function validateAnchorBlocks(value, numBlocks)
invalid = ~isnumeric(value) || ~isreal(value) || ~isvector(value) || ...
    isempty(value) || any(isinf(value(:)));
if ~invalid
    finiteValues = double(value(isfinite(value)));
    invalid = any(finiteValues ~= fix(finiteValues)) || ...
        any(finiteValues < 1) || any(finiteValues > numBlocks);
end
if invalid
    error('build_ppm_eye_set:InvalidAnchorBlocks', ...
        ['anchorBlocks must be a nonempty real numeric vector whose entries ', ...
        'are NaN or integers from 1 through info.NumBlocks.']);
end
end

function validateAnchorLabels(value, anchorCount)
validCell = iscellstr(value); %#ok<ISCLSTR>
validString = isstring(value) && ~any(ismissing(value(:)));
if ~(validCell || validString) || numel(value) ~= anchorCount
    error('build_ppm_eye_set:InvalidInfoField', ...
        ['info.AnchorLabels must be a cellstr or string array with one ', ...
        'entry per anchorBlocks element.']);
end
end

function validateTrace(value, numBlocks, integerRequired, name)
invalid = ~isnumeric(value) || ~isreal(value) || ~isrow(value) || ...
    numel(value) ~= numBlocks || any(~isfinite(value));
if ~invalid && integerRequired
    invalid = any(double(value) ~= fix(double(value)));
end
if invalid
    if integerRequired
        description = 'a finite integer numeric row';
    else
        description = 'a finite real numeric row';
    end
    error('build_ppm_eye_set:InvalidInfoField', ...
        '%s must be %s with info.NumBlocks entries.', name, description);
end
end

function validateInteger(value, minimum, name)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ...
        ~isfinite(value) || double(value) ~= fix(double(value)) || ...
        double(value) < minimum
    error('build_ppm_eye_set:InvalidInfoField', ...
        '%s must be an integer scalar greater than or equal to %d.', ...
        name, minimum);
end
end
