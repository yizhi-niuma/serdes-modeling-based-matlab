function summary = make_ppm_stage_eyes(varargin)
%MAKE_PPM_STAGE_EYES Rebuild staged FFE eyes from saved ppm runs.
%   SUMMARY = MAKE_PPM_STAGE_EYES() rebuilds fixed-coefficient FFE eyes at
%   the stage-1 SNR downshift, at the first satisfied lock verdict, and over
%   the final tail window for the saved -100, 0, and +100 ppm runs. The
%   saved traces are replayed offline; the CDR simulation is not rerun.
%
%   SUMMARY = MAKE_PPM_STAGE_EYES('Name', VALUE, ...) accepts:
%     ResultDirs       Bare names below the suite result directory, or
%                      absolute paths. A character row, string array, or
%                      cell array of character vectors is accepted.
%     UiCount          Requested eye length in UI (default 2048).
%     StartPhaseIndex  Saved result row to process. Empty selects the
%                      slowest locked capture row saved by the run.
%     SaveOutputs      Logical scalar controlling figure and CSV writes.
%     SummaryCsvName   CSV file name written in each result directory.
%
%   One summary struct is returned per result directory. Each element
%   contains the CSV scalars, three eye structs, set metadata, output paths,
%   result MAT-file path, and the three fixed coefficient snapshots.

thisFile = mfilename('fullpath');
suiteDir = fileparts(thisFile);
addpath(suiteDir);
paths = setup_cdr_three_loop_wi_ppm_paths();
options = parseOptions(varargin{:});
resultDirs = resolveResultDirs(options.ResultDirs, paths.ResultDir);
entries = cell(1, numel(resultDirs));

for directoryIndex = 1:numel(resultDirs)
    resultDir = resultDirs{directoryIndex};
    matPath = fullfile(resultDir, 'cdr_three_loop_ppm_result.mat');
    if ~isfile(matPath)
        error('make_ppm_stage_eyes:MissingResultMat', ...
            'Saved ppm result MAT-file does not exist: "%s".', matPath);
    end
    resultFile = matfile(matPath);
    result = resultFile.result;

    [adcBlockUi, preTapCount] = resolveSavedDescriptors(result);
    startPhaseIndex = selectStartPhaseIndex(result, options.StartPhaseIndex);
    selectedStartPhase = double(result.StartPhaseList(startPhaseIndex));
    captureBlock = double(result.FirstCaptureBlock(startPhaseIndex));
    numBlocks = double(result.NumBlocks);
    sps = double(result.SamplePerSymbol);

    cachePath = result.CachePath;
    if ~isfile(cachePath)
        error('make_ppm_stage_eyes:MissingCache', ...
            'Saved CTLE cache does not exist: "%s".', char(cachePath));
    end
    cacheFile = matfile(cachePath);
    firstSample = double(result.AnalysisStartUi) * sps + 1;
    lastSample = (double(result.AnalysisStartUi) + ...
        double(result.AnalysisNumUi)) * sps;
    segment = double(cacheFile.ctleOutput(1, firstSample:lastSample));

    coefficientTrace = selectedCoefficientTrace(result.FfeCoeffTrace, ...
        startPhaseIndex, numBlocks);
    snrSettleBlock = replaySnrSettle(result, startPhaseIndex);
    [lockBlock, freqOnlyLockBlock] = replayFirstLock( ...
        result, startPhaseIndex);
    stage2FireBlock = replayStage2Gate(result, startPhaseIndex);
    stage2Fired = isfinite(stage2FireBlock);
    stage2Note = stage2StatusText(stage2FireBlock, ...
        stage2GateCriterion(result));

    info = struct();
    info.SamplesPerUi = sps;
    info.NumBlocks = numBlocks;
    info.AdcBlockUi = adcBlockUi;
    info.BaseUi = double(result.BaseUi);
    info.AnalysisStartUi = double(result.AnalysisStartUi);
    info.PreTapCount = preTapCount;
    info.AdcBits = double(result.AdcResolutionBits);
    info.AdcRange = double(result.AdcFullRange);
    info.SelectedStartPhase = selectedStartPhase;
    info.FreqOffsetPpm = double(result.FreqOffsetPpm);
    info.AnchorLabels = {'FFE eye after stage-1 SNR downshift', ...
        'FFE eye after lock criterion satisfied'};
    info.PhaseCodeTrace = reshape(double( ...
        result.PhaseCodeTrace(startPhaseIndex, :)), 1, []);
    info.UiSlipTrace = reshape(double( ...
        result.UiSlipTrace(startPhaseIndex, :)), 1, []);
    info.DriftSampleTrace = reshape(double( ...
        result.DriftSampleTrace(startPhaseIndex, :)), 1, []);
    info.EyePhaseUnwrappedTrace = reshape(double( ...
        result.EyePhaseUnwrappedTrace(startPhaseIndex, :)), 1, []);
    info.FfeCoeffTrace = coefficientTrace;

    anchorBlocks = [snrSettleBlock, lockBlock];
    [eyes, setMeta] = build_ppm_eye_set( ...
        segment, info, anchorBlocks, options.UiCount);
    if ~isfield(eyes(end), 'AnchorLabel') || isempty(eyes(end).AnchorLabel)
        eyes(end).AnchorLabel = 'Final FFE eye';
    end

    windowLength = min(double(result.LockWindowBlocks), numBlocks);
    frequencyTail = double(result.LoopFrequencyStateTrace( ...
        startPhaseIndex, end - windowLength + 1:end));
    measuredFrequencyState = mean(frequencyTail);

    plotConfig = struct();
    plotConfig.ResultDir = resultDir;
    plotConfig.SaveOutputs = options.SaveOutputs;
    plotConfig.UiCountRequested = options.UiCount;
    plotConfig.FreqOffsetPpm = double(result.FreqOffsetPpm);
    plotConfig.SelectedStartPhase = selectedStartPhase;
    plotConfig.NumBlocks = numBlocks;
    plotConfig.RowSlugs = {'at_snr_settle', 'at_lock', 'final'};
    plotConfig.Stage2Note = stage2Note;
    plotConfig.ExpectedFreqStateCodePerBlock = ...
        double(result.ExpectedFreqState);
    plotConfig.MeasuredFreqStateCodePerBlock = measuredFrequencyState;
    figurePaths = plot_ppm_eye_set(eyes, plotConfig);

    markerCodes = reshape(double(setMeta.MarkerCode), 1, []);
    markerSpans = reshape(double(setMeta.MarkerSpanCode), 1, []);
    startUi = reshape(double(setMeta.StartUi), 1, []);
    markerDeltaSettleToFinal = wrappedMarkerDelta( ...
        markerCodes(3), markerCodes(1), sps);
    markerDeltaLockToFinal = wrappedMarkerDelta( ...
        markerCodes(3), markerCodes(2), sps);
    snrSettleCoefficients = coefficientSnapshot( ...
        coefficientTrace, snrSettleBlock);
    lockCoefficients = coefficientSnapshot(coefficientTrace, lockBlock);
    finalCoefficients = reshape(coefficientTrace(end, :), 1, []);

    entry = struct();
    entry.ResultDir = resultDir;
    entry.FreqOffsetPpm = double(result.FreqOffsetPpm);
    entry.StartPhaseIndex = startPhaseIndex;
    entry.StartPhase = selectedStartPhase;
    entry.LockedFlag = logical(result.LockedFlag(startPhaseIndex));
    entry.NumBlocks = numBlocks;
    entry.UiCountRequested = double(options.UiCount);
    entry.CaptureBlock = captureBlock;
    entry.SnrSettleBlock = snrSettleBlock;
    entry.LockBlock = lockBlock;
    entry.FreqOnlyLockBlock = freqOnlyLockBlock;
    entry.RotationCriterionApplicable = ...
        logical(result.RotationCriterionApplicable);
    entry.Stage2FireBlock = stage2FireBlock;
    entry.Stage2Fired = stage2Fired;
    entry.SnrSettleMarkerCode = markerCodes(1);
    entry.LockMarkerCode = markerCodes(2);
    entry.FinalMarkerCode = markerCodes(3);
    entry.SnrSettleSpanCode = markerSpans(1);
    entry.LockSpanCode = markerSpans(2);
    entry.FinalSpanCode = markerSpans(3);
    entry.SnrSettleStartUi = startUi(1);
    entry.LockStartUi = startUi(2);
    entry.FinalStartUi = startUi(3);
    entry.MarkerDeltaSettleToFinal = markerDeltaSettleToFinal;
    entry.MarkerDeltaLockToFinal = markerDeltaLockToFinal;
    entry.ExpectedFreqState = double(result.ExpectedFreqState);
    entry.MeasuredFreqState = measuredFrequencyState;
    entry.SnrSettleEyeValid = logical(eyes(1).Valid);
    entry.LockEyeValid = logical(eyes(2).Valid);
    entry.FinalEyeValid = logical(eyes(3).Valid);
    entry.Eyes = eyes;
    entry.SetMeta = setMeta;
    entry.Paths = figurePaths;
    entry.MatPath = matPath;
    entry.SnrSettleCoefficients = snrSettleCoefficients;
    entry.LockCoefficients = lockCoefficients;
    entry.FinalCoefficients = finalCoefficients;

    if options.SaveOutputs
        summaryPath = fullfile(resultDir, options.SummaryCsvName);
        writetable(summaryTable(entry), summaryPath);
        lockSummaryTxtPath = write_ppm_lock_summary_txt(result, ...
            fullfile(resultDir, 'ppm_lock_summary.txt'));
        entry.LockSummaryTxtPath = lockSummaryTxtPath;
        fprintf('Wrote ppm lock summary "%s".\n', lockSummaryTxtPath);
        removeStaleOutputs(resultDir);
    end
    entries{directoryIndex} = entry;
    fprintf(['Rebuilt ppm stage eyes in "%s": start phase %g, SNR settle ', ...
        'block %g, lock block %g, stage-2 block %g, valid=[%d %d %d].\n'], ...
        resultDir, selectedStartPhase, snrSettleBlock, lockBlock, ...
        stage2FireBlock, entry.SnrSettleEyeValid, entry.LockEyeValid, ...
        entry.FinalEyeValid);
end

summary = [entries{:}];
end

function options = parseOptions(varargin)
defaults = struct();
defaults.ResultDirs = {'cdr_three_loop_ppm_m100', ...
    'cdr_three_loop_ppm_p0', 'cdr_three_loop_ppm_p100'};
defaults.UiCount = 2048;
defaults.StartPhaseIndex = [];
defaults.SaveOutputs = true;
defaults.SummaryCsvName = 'ppm_stage_eye_summary.csv';
options = defaults;
optionNames = fieldnames(defaults);

if mod(numel(varargin), 2) ~= 0
    error('make_ppm_stage_eyes:InvalidNameValuePairs', ...
        'Options must be supplied as name-value pairs.');
end
for argumentIndex = 1:2:numel(varargin)
    suppliedName = varargin{argumentIndex};
    if isstring(suppliedName) && isscalar(suppliedName) && ...
            ~ismissing(suppliedName)
        suppliedName = char(suppliedName);
    end
    if ~(ischar(suppliedName) && isrow(suppliedName))
        error('make_ppm_stage_eyes:UnknownOption', ...
            'Option names must be character rows or string scalars.');
    end
    matchedIndex = find(strcmpi(suppliedName, optionNames), 1);
    if isempty(matchedIndex)
        error('make_ppm_stage_eyes:UnknownOption', ...
            'Unknown option "%s".', suppliedName);
    end
    canonicalName = optionNames{matchedIndex};
    options.(canonicalName) = varargin{argumentIndex + 1};
end

options.ResultDirs = validateResultDirs(options.ResultDirs);
if ~isIntegerScalarAtLeast(options.UiCount, 2)
    error('make_ppm_stage_eyes:InvalidUiCount', ...
        'UiCount must be a finite real integer scalar greater than or equal to 2.');
end
options.UiCount = double(options.UiCount);
validateStartPhaseIndexOption(options.StartPhaseIndex);
if ~isempty(options.StartPhaseIndex)
    options.StartPhaseIndex = double(options.StartPhaseIndex);
end
if ~islogical(options.SaveOutputs) || ~isscalar(options.SaveOutputs)
    error('make_ppm_stage_eyes:InvalidSaveOutputs', ...
        'SaveOutputs must be a logical scalar.');
end
options.SummaryCsvName = validateSummaryCsvName(options.SummaryCsvName);
end

function resultDirs = validateResultDirs(value)
if ischar(value) && isrow(value)
    resultDirs = {value};
elseif isstring(value)
    if any(ismissing(value(:)))
        error('make_ppm_stage_eyes:InvalidResultDirs', ...
            'ResultDirs string entries must not be missing.');
    end
    resultDirs = cellstr(reshape(value, 1, []));
elseif isCellArrayOfCharacterVectors(value)
    resultDirs = reshape(value, 1, []);
else
    error('make_ppm_stage_eyes:InvalidResultDirs', ...
        'ResultDirs must be a character row, string array, or cellstr.');
end
if isempty(resultDirs)
    error('make_ppm_stage_eyes:InvalidResultDirs', ...
        'ResultDirs must contain at least one directory.');
end
for directoryIndex = 1:numel(resultDirs)
    if isempty(strtrim(resultDirs{directoryIndex}))
        error('make_ppm_stage_eyes:InvalidResultDirs', ...
            'ResultDirs entries must be nonempty directory names or paths.');
    end
end
end

function validateStartPhaseIndexOption(value)
if isnumeric(value) && isreal(value) && isempty(value)
    return;
end
if ~isnumeric(value) || ~isreal(value) || ~isscalar(value)
    error('make_ppm_stage_eyes:InvalidStartPhaseIndex', ...
        'StartPhaseIndex must be empty or a real numeric scalar.');
end
if isfinite(value) && (double(value) ~= fix(double(value)) || double(value) < 1)
    error('make_ppm_stage_eyes:InvalidStartPhaseIndex', ...
        'A finite StartPhaseIndex must be a positive integer scalar.');
end
end

function name = validateSummaryCsvName(value)
if isstring(value) && isscalar(value) && ~ismissing(value)
    value = char(value);
end
if ~(ischar(value) && isrow(value)) || isempty(strtrim(value))
    error('make_ppm_stage_eyes:InvalidSummaryCsvName', ...
        'SummaryCsvName must be a nonempty character row or string scalar.');
end
[folder, fileName, extension] = fileparts(value);
if ~isempty(folder) || isempty([fileName extension]) || any(value == '/') || ...
        any(value == '\')
    error('make_ppm_stage_eyes:InvalidSummaryCsvName', ...
        'SummaryCsvName must be a file name without a directory component.');
end
name = value;
end

function resultDirs = resolveResultDirs(names, resultRoot)
resultDirs = cell(size(names));
for directoryIndex = 1:numel(names)
    if isAbsolutePath(names{directoryIndex})
        resultDirs{directoryIndex} = names{directoryIndex};
    else
        resultDirs{directoryIndex} = fullfile(resultRoot, names{directoryIndex});
    end
end
end

function tf = isAbsolutePath(pathText)
if ispc
    hasDriveRoot = numel(pathText) >= 3 && pathText(2) == ':' && ...
        any(pathText(3) == ['\' '/']);
    hasUncRoot = numel(pathText) >= 2 && ...
        (strncmp(pathText, '\\', 2) || strncmp(pathText, '//', 2));
    tf = hasDriveRoot || hasUncRoot;
else
    tf = ~isempty(pathText) && pathText(1) == '/';
end
end

function [adcBlockUi, preTapCount] = resolveSavedDescriptors(result)
if isfield(result, 'AdcBlockUi')
    adcBlockUi = double(result.AdcBlockUi);
else
    adcBlockUi = 64;
    warning('make_ppm_stage_eyes:LegacyResultMat', ...
        ['The saved result is missing result.AdcBlockUi; assuming ', ...
        'AdcBlockUi = 64 because the MAT-file predates this field.']);
end
if isfield(result, 'CdrFfePreTapCount')
    preTapCount = double(result.CdrFfePreTapCount);
else
    preTapCount = double(result.CdrFfeMainTapIndex) - 1;
    warning('make_ppm_stage_eyes:LegacyResultMat', ...
        ['The saved result is missing result.CdrFfePreTapCount; assuming ', ...
        'CdrFfePreTapCount = %g from result.CdrFfeMainTapIndex - 1 because ', ...
        'the MAT-file predates this field.'], preTapCount);
end
end

function index = selectStartPhaseIndex(result, requestedIndex)
if isempty(requestedIndex)
    selectedIndex = result.SlowestCapturePhaseIndex;
else
    selectedIndex = requestedIndex;
end
if ~isnumeric(selectedIndex) || ~isreal(selectedIndex) || ...
        ~isscalar(selectedIndex) || ~isfinite(selectedIndex)
    error('make_ppm_stage_eyes:NoLockedPhase', ...
        'No locked start phase was selected in that run.');
end
phaseCount = numel(result.StartPhaseList);
if double(selectedIndex) ~= fix(double(selectedIndex)) || ...
        double(selectedIndex) < 1 || double(selectedIndex) > phaseCount
    error('make_ppm_stage_eyes:InvalidStartPhaseIndex', ...
        'StartPhaseIndex must be an integer from 1 through %d for this run.', ...
        phaseCount);
end
index = double(selectedIndex);
end

function trace = selectedCoefficientTrace(savedTrace, rowIndex, numBlocks)
trace = squeeze(double(savedTrace(rowIndex, :, :)));
if numBlocks == 1
    trace = reshape(trace, 1, []);
elseif isvector(trace)
    trace = reshape(trace, numBlocks, []);
end
end

function settleBlock = replaySnrSettle(result, rowIndex)
settleBlock = NaN;
% SNR EWMA is the sole stage-1 gate since 2026-09-26 (the legacy dLev/SettleGate
% path was removed), so no gate-selection field is checked here.
requiredFields = {'SnrDbTrace', 'SnrSettleAlpha', ...
    'SnrSettleThresholdDb', 'SnrSettleMinBlock'};
if ~all(isfield(result, requiredFields))
    return;
end
alpha = result.SnrSettleAlpha;
thresholdDb = result.SnrSettleThresholdDb;
minBlock = result.SnrSettleMinBlock;
if ~isnumeric(alpha) || ~isreal(alpha) || ~isscalar(alpha) || ...
        ~isfinite(alpha) || alpha <= 0 || alpha > 1 || ...
        ~isnumeric(thresholdDb) || ~isreal(thresholdDb) || ...
        ~isscalar(thresholdDb) || ~isfinite(thresholdDb) || ...
        ~isIntegerScalarAtLeast(minBlock, 1) || ...
        ~isnumeric(result.SnrDbTrace) || ~isreal(result.SnrDbTrace) || ...
        rowIndex > size(result.SnrDbTrace, 1)
    return;
end
snrTrace = reshape(double(result.SnrDbTrace(rowIndex, :)), 1, []);
ewmaDb = NaN;
for blockIndex = 1:numel(snrTrace)
    snrDb = snrTrace(blockIndex);
    if ~isfinite(snrDb)
        continue;
    end
    if isnan(ewmaDb)
        ewmaDb = snrDb;
    else
        ewmaDb = (1 - double(alpha)) * ewmaDb + double(alpha) * snrDb;
    end
    if blockIndex < double(minBlock)
        continue;
    end
    if ewmaDb >= double(thresholdDb)
        settleBlock = blockIndex;
        return;
    end
end
end

function [lockBlock, freqOnlyLockBlock] = replayFirstLock(result, rowIndex)
lockBlock = NaN;
freqOnlyLockBlock = NaN;
numBlocks = double(result.NumBlocks);
windowBlocks = min(double(result.LockWindowBlocks), numBlocks);
unwrappedTrace = reshape(double( ...
    result.UnwrappedPhaseTrace(rowIndex, :)), 1, []);
if logical(result.IsZeroPpm)
    for blockIndex = windowBlocks:numBlocks
        windowIndex = (blockIndex - windowBlocks + 1):blockIndex;
        locked = detect_pi_center_touch_lock( ...
            unwrappedTrace(windowIndex), windowBlocks, ...
            result.LockMinEvents, result.LockBandHalfWidth, ...
            result.SamplePerSymbol);
        if locked
            lockBlock = blockIndex;
            return;
        end
    end
    return;
end

frequencyTrace = reshape(double( ...
    result.LoopFrequencyStateTrace(rowIndex, :)), 1, []);
runOptions = result.RunOptions;
rotationApplicable = logical(result.RotationCriterionApplicable);
for blockIndex = windowBlocks:numBlocks
    windowIndex = (blockIndex - windowBlocks + 1):blockIndex;
    frequencyLocked = loop_monitor.detectFrequencyStateLock( ...
        frequencyTrace(windowIndex), windowBlocks, ...
        result.ExpectedFreqState, runOptions.FreqMeanHalfDiffTol, ...
        runOptions.FreqStdTol, runOptions.FreqRateTol);
    if frequencyLocked && isnan(freqOnlyLockBlock)
        freqOnlyLockBlock = blockIndex;
    end
    if rotationApplicable
        rotationLocked = loop_monitor.detectRotationPeriodLock( ...
            unwrappedTrace(windowIndex), windowBlocks, ...
            result.SamplePerSymbol, runOptions.RotMinIntervals, ...
            runOptions.RotCovTol, result.ExpectedRotationPeriodBlocks, ...
            result.RotPeriodTolBlocks);
    else
        % The saved verdict records rotation as not applicable at this offset.
        rotationLocked = true;
    end
    if frequencyLocked && rotationLocked
        lockBlock = blockIndex;
        return;
    end
end
end

function criterion = stage2GateCriterion(result)
%STAGE2GATECRITERION Which stage-2 gate the saved run actually armed.
% Result MATs written before the gate became switchable carry no field; those
% runs could only have used center-touch.
criterion = 'center-touch';
if isfield(result, 'FfeGateCriterion')
    value = result.FfeGateCriterion;
    if (ischar(value) && isrow(value)) || ...
            (isstring(value) && isscalar(value) && ~ismissing(value))
        candidate = char(value);
        if ~isempty(candidate)
            criterion = candidate;
        end
    end
end
end

function fireBlock = replayStage2Gate(result, rowIndex)
%REPLAYSTAGE2GATE Stage-2 downshift block for one start phase.
% The run records the block at which the armed gate actually fired, so that
% value is authoritative. Only legacy MATs that predate the field need the
% center-touch replay below; replaying unconditionally would report NaN for
% every freq-state run, because a ramping code never latches center-touch.
if isfield(result, 'Stage2GateBlock')
    blocks = result.Stage2GateBlock;
    if rowIndex <= numel(blocks)
        fireBlock = double(blocks(rowIndex));
        return;
    end
end

% 旧 MAT 没有 Stage2GateBlock 字段。此前这里会回放 center-touch 写门控来补算
% 该块号，但该门控已于 2026-09-30 随重构从 loop_monitor 整体删除(它在有频偏时
% 因 PI code 持续爬升而永不触发，已被 freq-state 判据取代)，因此无法再回放。
% 这里如实返回 NaN 并告警，而不是改用另一条语义不同的判据冒充原结果。
warning('make_ppm_stage_eyes:Stage2GateBlockUnavailable', ...
    ['结果 MAT 缺少 Stage2GateBlock 字段，且 center-touch 写门控已从 ' ...
    'loop_monitor 删除、无法回放，第 %d 个起始相位的 stage-2 块号记为 NaN。'], ...
    rowIndex);
fireBlock = NaN;
end

function textValue = stage2StatusText(fireBlock, gateCriterion)
if isfinite(fireBlock)
    textValue = sprintf( ...
        'stage-2 mu downshift fired at block %d (gate: %s)', ...
        fireBlock, gateCriterion);
elseif strcmpi(gateCriterion, 'freq-state')
    textValue = ['stage-2 mu downshift did NOT fire (freq-state gate: the ', ...
        'frequencyState mean never held inside the tolerance band)'];
else
    textValue = ['stage-2 mu downshift did NOT fire (FfeGate center-touch ', ...
        'on raw PI code did not latch for this start phase)'];
end
end

function delta = wrappedMarkerDelta(finalCode, anchorCode, samplesPerUi)
if ~isfinite(finalCode) || ~isfinite(anchorCode)
    delta = NaN;
    return;
end
% Markers are modulo one UI, so wrap the walk into (-sps/2, sps/2].
halfUi = samplesPerUi / 2;
delta = mod(double(finalCode) - double(anchorCode) + halfUi, ...
    samplesPerUi) - halfUi;
if delta <= -halfUi
    delta = delta + samplesPerUi;
end
end

function coefficients = coefficientSnapshot(trace, blockIndex)
if isnumeric(blockIndex) && isreal(blockIndex) && isscalar(blockIndex) && ...
        isfinite(blockIndex) && blockIndex == fix(blockIndex) && ...
        blockIndex >= 1 && blockIndex <= size(trace, 1)
    coefficients = reshape(trace(blockIndex, :), 1, []);
else
    coefficients = nan(1, size(trace, 2));
end
end

function outputTable = summaryTable(entry)
outputTable = table({entry.ResultDir}, entry.FreqOffsetPpm, ...
    entry.StartPhaseIndex, entry.StartPhase, entry.LockedFlag, ...
    entry.NumBlocks, entry.UiCountRequested, entry.CaptureBlock, ...
    entry.SnrSettleBlock, entry.LockBlock, entry.FreqOnlyLockBlock, ...
    entry.RotationCriterionApplicable, entry.Stage2FireBlock, ...
    entry.Stage2Fired, entry.SnrSettleMarkerCode, entry.LockMarkerCode, ...
    entry.FinalMarkerCode, entry.SnrSettleSpanCode, entry.LockSpanCode, ...
    entry.FinalSpanCode, entry.SnrSettleStartUi, entry.LockStartUi, ...
    entry.FinalStartUi, entry.MarkerDeltaSettleToFinal, ...
    entry.MarkerDeltaLockToFinal, entry.ExpectedFreqState, ...
    entry.MeasuredFreqState, entry.SnrSettleEyeValid, ...
    entry.LockEyeValid, entry.FinalEyeValid, ...
    'VariableNames', {'ResultDir', 'FreqOffsetPpm', 'StartPhaseIndex', ...
    'StartPhase', 'LockedFlag', 'NumBlocks', 'UiCountRequested', ...
    'CaptureBlock', 'SnrSettleBlock', 'LockBlock', 'FreqOnlyLockBlock', ...
    'RotationCriterionApplicable', 'Stage2FireBlock', 'Stage2Fired', ...
    'SnrSettleMarkerCode', 'LockMarkerCode', 'FinalMarkerCode', ...
    'SnrSettleSpanCode', 'LockSpanCode', 'FinalSpanCode', ...
    'SnrSettleStartUi', 'LockStartUi', 'FinalStartUi', ...
    'MarkerDeltaSettleToFinal', 'MarkerDeltaLockToFinal', ...
    'ExpectedFreqState', 'MeasuredFreqState', 'SnrSettleEyeValid', ...
    'LockEyeValid', 'FinalEyeValid'});
end

function removeStaleOutputs(resultDir)
% Outputs of the retired two-eye driver whose meaning no longer exists.
% cdr_ffe_eye_final_2048ui.fig is deliberately NOT listed: the final tail
% window is unchanged, so the third row of this driver simply overwrites it.
% Listing it here would delete the standalone final eye right after writing it.
staleNames = {'cdr_ffe_eye_at_capture_2048ui.fig', ...
    'cdr_ffe_eye_capture_vs_final.fig', 'ppm_eye_summary.csv'};
for fileIndex = 1:numel(staleNames)
    stalePath = fullfile(resultDir, staleNames{fileIndex});
    if isfile(stalePath)
        delete(stalePath);
        fprintf('Removed retired ppm eye artefact "%s".\n', stalePath);
    end
end
end

function tf = isIntegerScalarAtLeast(value, minimumValue)
tf = isnumeric(value) && isreal(value) && isscalar(value) && ...
    isfinite(value) && double(value) == fix(double(value)) && ...
    double(value) >= minimumValue;
end

function tf = isCellArrayOfCharacterVectors(value)
tf = iscell(value);
if ~tf
    return;
end
for index = 1:numel(value)
    if ~(ischar(value{index}) && isrow(value{index}))
        tf = false;
        return;
    end
end
end
