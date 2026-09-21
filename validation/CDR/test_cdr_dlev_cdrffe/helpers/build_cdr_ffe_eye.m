function eye = build_cdr_ffe_eye(ctleSegment, startUi, uiCount, samplesPerUi, coefficients, preTapCount, adcBits, adcRange)
%BUILD_CDR_FFE_EYE Build a phase-resolved, fixed-tap CDR FFE eye density.
%   EYE = BUILD_CDR_FFE_EYE(CTLESEGMENT, STARTUI, UICOUNT, SAMPLESPERUI,
%   COEFFICIENTS, PRETAPCOUNT, ADCBITS, ADCRANGE) converts a complete
%   oversampled CTLE interval with the repository's ideal TI-ADC SAR core,
%   then evaluates the repository CDR FFE independently at every cached
%   sub-UI phase. STARTUI is the zero-based index of the first target UI.
%
%   The conversion is equivalent to using identically configured ideal SAR
%   lanes: an ideal lane has no lane-dependent state or nonideality, so one
%   vector conversion gives exactly the same codes as serially reordering
%   identically configured lanes. Unsigned ADC codes are centered by
%   subtracting 2^(ADCBITS-1); no waveform scaling or custom quantizer is
%   applied.
%
%   Density columns describe overlapping consecutive two-UI traces. Thus
%   every input UI participates, while interior UIs appear in two adjacent
%   traces; the columns are not independent waveform samples.

validateInputs(ctleSegment, startUi, uiCount, samplesPerUi, ...
    coefficients, preTapCount, adcBits, adcRange);

% Convert integer-valued scalar classes before index arithmetic. This also
% keeps uint inputs from changing the arithmetic type of sample indices.
startUi = double(startUi);
uiCount = double(uiCount);
samplesPerUi = double(samplesPerUi);
preTapCount = double(preTapCount);
adcBits = double(adcBits);
coefficients = reshape(double(coefficients), 1, []);
adcRange = reshape(double(adcRange), 1, []);
ctleSegment = reshape(double(ctleSegment), 1, []);

postTapCount = numel(coefficients) - preTapCount - 1;
firstSample = (startUi - postTapCount) * samplesPerUi + 1;
lastSample = (startUi + uiCount + preTapCount) * samplesPerUi;
if firstSample < 1 || lastSample > numel(ctleSegment)
    error('build_cdr_ffe_eye:InsufficientMargin', ...
        ['ctleSegment does not contain the required complete-UI margins: ', ...
         '%d post-tap UI(s) before startUi and %d pre-tap UI(s) after the target interval.'], ...
        postTapCount, preTapCount);
end

% Resolve paths from this file rather than from the MATLAB working folder.
% TI_ADC is prepended deliberately because other repository folders contain
% classes with the same sar_adc_core name.
originalPath = path;
pathCleanup = onCleanup(@() path(originalPath));
helperDir = fileparts(mfilename('fullpath'));
suiteRoot = fileparts(helperDir);
addpath(suiteRoot);
p = setup_cdr_dlev_cdrffe_paths();
repoRoot = p.RepoRoot;
tiAdcSourceDir = fullfile(repoRoot, 'src', 'ADC', 'TI_ADC');
cdrSourceDir = fullfile(repoRoot, 'src', 'CDR');
addpath(tiAdcSourceDir, '-begin');
addpath(cdrSourceDir, '-begin');
expectedSarCore = fullfile(tiAdcSourceDir, 'sar_adc_core.m');
resolvedSarCore = which('sar_adc_core');
if ~samePath(resolvedSarCore, expectedSarCore)
    error('build_cdr_ffe_eye:WrongSarAdcCore', ...
        'sar_adc_core must resolve to "%s", but MATLAB resolved "%s".', expectedSarCore, resolvedSarCore);
end

conversionVoltage = ctleSegment(firstSample:lastSample);
adc = sar_adc_core(adcRange(1), adcRange(2), adcBits);
unsignedCodes = adc.convertVectorFast(conversionVoltage);
centeredCodes = double(unsignedCodes) - 2^(adcBits - 1);
completeUiCount = postTapCount + uiCount + preTapCount;
codeByPhaseAndUi = reshape(centeredCodes, samplesPerUi, completeUiCount);

fixedFfe = cdr_ffe(coefficients, preTapCount);
outputCodeGrid = zeros(samplesPerUi, uiCount);
for phaseIndex = 1:samplesPerUi
    outputCodeGrid(phaseIndex, :) = fixedFfe.processBlock(codeByPhaseAndUi(phaseIndex, :));
end
if any(~isfinite(outputCodeGrid(:)))
    error('build_cdr_ffe_eye:NonfiniteOutput', 'The fixed-tap FFE produced a non-finite output code.');
end

% Each column is one continuous two-UI trajectory. The second half of trace
% k is the first half of trace k+1, so density conserves exactly
% 2*samplesPerUi*(uiCount-1) accumulated observations.
twoUiTraces = [outputCodeGrid(:, 1:end-1); outputCodeGrid(:, 2:end)];
minimumCode = min(outputCodeGrid(:));
maximumCode = max(outputCodeGrid(:));
binWidth = 0.5;
lowerEdge = floor(minimumCode / binWidth) * binWidth;
binCount = max(1, ceil((maximumCode - lowerEdge) / binWidth));
codeBinEdges = lowerEdge + (0:binCount) * binWidth;
% Guard against a last-edge roundoff undershoot without changing bin width.
if codeBinEdges(end) < maximumCode
    codeBinEdges(end + 1) = codeBinEdges(end) + binWidth;
end
codeBinCenters = (codeBinEdges(1:end-1) + codeBinEdges(2:end)) / 2;
density = zeros(numel(codeBinCenters), 2 * samplesPerUi);
for phaseIndex = 1:(2 * samplesPerUi)
    density(:, phaseIndex) = histcounts(twoUiTraces(phaseIndex, :), codeBinEdges).';
end

expectedDensityCount = 2 * samplesPerUi * (uiCount - 1);
if sum(density(:)) ~= expectedDensityCount
    error('build_cdr_ffe_eye:DensityConservation', ...
        'Eye histogram lost samples: expected %d observations and accumulated %d.', ...
        expectedDensityCount, sum(density(:)));
end

eye = struct();
eye.Valid = true;
eye.Reason = '';
eye.OutputCodeGrid = outputCodeGrid;
eye.UiCountUsed = uiCount;
eye.StartUi = startUi;
eye.Coefficients = coefficients;
eye.SamplesPerUi = samplesPerUi;
eye.PhaseUi = (0:(2 * samplesPerUi - 1)) / samplesPerUi;
eye.CodeBinCenters = codeBinCenters;
eye.CodeBinEdges = codeBinEdges;
eye.Density = density;
eye.TraceCount = uiCount - 1;
eye.Minimum = minimumCode;
eye.Maximum = maximumCode;
end

function validateInputs(ctleSegment, startUi, uiCount, samplesPerUi, coefficients, preTapCount, adcBits, adcRange)
if ~isnumeric(ctleSegment) || ~isreal(ctleSegment) || ~isvector(ctleSegment) || ...
        isempty(ctleSegment) || any(~isfinite(ctleSegment(:)))
    error('build_cdr_ffe_eye:InvalidCtLeSegment', ...
        'ctleSegment must be a nonempty finite real numeric row or column vector.');
end
validateIntegerScalar(startUi, 0, 'startUi', 'build_cdr_ffe_eye:InvalidStartUi');
validateIntegerScalar(uiCount, 2, 'uiCount', 'build_cdr_ffe_eye:InvalidUiCount');
validateIntegerScalar(samplesPerUi, 1, 'samplesPerUi', 'build_cdr_ffe_eye:InvalidSamplesPerUi');
if ~isnumeric(coefficients) || ~isreal(coefficients) || ~isvector(coefficients) || ...
        isempty(coefficients) || any(~isfinite(coefficients(:)))
    error('build_cdr_ffe_eye:InvalidCoefficients', ...
        'coefficients must be a nonempty finite real numeric vector.');
end
validateIntegerScalar(preTapCount, 0, 'preTapCount', 'build_cdr_ffe_eye:InvalidPreTapCount');
if double(preTapCount) >= numel(coefficients)
    error('build_cdr_ffe_eye:InvalidPreTapCount', ...
        'preTapCount must be an integer from 0 through numel(coefficients)-1.');
end
mainTapIndex = double(preTapCount) + 1;
if double(coefficients(mainTapIndex)) ~= 1
    error('build_cdr_ffe_eye:InvalidMainTap', ...
        'The coefficient at preTapCount+1 must be the fixed main tap value 1.');
end
validateIntegerScalar(adcBits, 1, 'adcBits', 'build_cdr_ffe_eye:InvalidAdcBits');
if double(adcBits) > 24
    error('build_cdr_ffe_eye:InvalidAdcBits', 'adcBits must be no greater than 24.');
end
if ~isnumeric(adcRange) || ~isreal(adcRange) || ~isvector(adcRange) || ...
        numel(adcRange) ~= 2 || any(~isfinite(adcRange(:))) || double(adcRange(2)) <= double(adcRange(1))
    error('build_cdr_ffe_eye:InvalidAdcRange', ...
        'adcRange must be a finite real two-element vector [VL VH] with VH greater than VL.');
end
end

function validateIntegerScalar(value, minimumValue, name, identifier)
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value) || ~isfinite(value) || ...
        double(value) ~= fix(double(value)) || double(value) < minimumValue
    error(identifier, '%s must be a finite integer scalar greater than or equal to %d.', name, minimumValue);
end
end

function tf = samePath(firstPath, secondPath)
firstPath = strrep(char(firstPath), '\', '/');
secondPath = strrep(char(secondPath), '\', '/');
if ispc
    tf = strcmpi(firstPath, secondPath);
else
    tf = strcmp(firstPath, secondPath);
end
end
