function txtPath = write_ppm_lock_summary_txt(result, txtPath)
%WRITE_PPM_LOCK_SUMMARY_TXT Write the per-start-phase ppm lock summary.

if nargin ~= 2
    error('write_ppm_lock_summary_txt:InvalidInputCount', ...
        'Expected result and txtPath inputs.');
end
txtPath = validateInputs(result, txtPath);

phaseCount = numel(result.StartPhaseList);
numBlocks = double(result.NumBlocks);
windowBlocks = min(double(result.LockWindowBlocks), numBlocks);
% Which stage-2 gate was armed, and whether the PI was modelled with INL.
% Both fields postdate the earliest result MATs, so fall back to a marker
% instead of erroring on a legacy file.
gateCriterion = optionalTextField(result, 'FfeGateCriterion', 'unrecorded');
piNonidealText = optionalTextField(result, 'PiNonideal', 'unrecorded');
isFreqStateGate = strcmpi(gateCriterion, 'freq-state');
stage1Block = nan(1, phaseCount);
lockBlock = nan(1, phaseCount);
stage2Block = nan(1, phaseCount);
stage1Phase = nan(1, phaseCount);
lockPhaseAtBlock = nan(1, phaseCount);
for rowIndex = 1:phaseCount
    stage1Block(rowIndex) = replaySnrSettle(result, rowIndex);
    lockBlock(rowIndex) = replayFirstLock(result, rowIndex);
    stage2Block(rowIndex) = replayStage2Gate(result, rowIndex);
    stage1Phase(rowIndex) = phaseAtBlock(result, rowIndex, ...
        stage1Block(rowIndex));
    lockPhaseAtBlock(rowIndex) = phaseAtBlock(result, rowIndex, ...
        lockBlock(rowIndex));
end

[fileId, message] = fopen(txtPath, 'w');
if fileId == -1
    error('write_ppm_lock_summary_txt:CannotOpenFile', ...
        'Cannot open "%s" for writing: %s', txtPath, message);
end
fileCleanup = onCleanup(@() fclose(fileId));

resultDir = fileparts(txtPath);
[~, resultLeaf] = fileparts(resultDir);
if isempty(resultLeaf)
    resultLeaf = resultDir;
end
separator = repmat('=', 1, 80);
rule = repmat('-', 1, 80);
rotationApplicable = logical(result.RotationCriterionApplicable);
freqStateMean = arrayfun(@(item) double(item.MeanValue), ...
    result.FreqLockDiagnostics);
rotationPeriod = arrayfun(@(item) double(item.PeriodMean), ...
    result.RotationLockDiagnostics);
rotationCov = arrayfun(@(item) double(item.PeriodCov), ...
    result.RotationLockDiagnostics);
if ~rotationApplicable
    rotationPeriod(:) = NaN;
end

fprintf(fileId, '%s\n', separator);
fprintf(fileId, 'CDR three-loop ppm lock summary : %s\n', resultLeaf);
fprintf(fileId, '%s\n', separator);
fprintf(fileId, 'Runner           : cdr_three_loop_ppm\n');
fprintf(fileId, 'FreqOffsetPpm    : %+g\n', double(result.FreqOffsetPpm));
fprintf(fileId, 'NumBlocks        : %d      StartPhases : %d\n', ...
    numBlocks, phaseCount);
fprintf(fileId, 'LockMode         : %s     LockWindowBlocks : %d\n', ...
    char(result.LockMode), windowBlocks);
fprintf(fileId, 'ExpectedFreqState        : %g code/block\n', ...
    double(result.ExpectedFreqState));
fprintf(fileId, ['ExpectedRotationPeriod   : %g block/UI   ', ...
    '(applicable = %d)\n'], double(result.ExpectedRotationPeriodBlocks), ...
    rotationApplicable);
fprintf(fileId, ['SnrSettleThresholdDb     : %g dB   alpha = %g   ', ...
    'minBlock = %d\n'], double(result.SnrSettleThresholdDb), ...
    double(result.SnrSettleAlpha), double(result.SnrSettleMinBlock));
fprintf(fileId, 'FfeGateCriterion : %s   (stage-2 mu downshift gate)\n', ...
    gateCriterion);
fprintf(fileId, 'PiNonideal       : %s\n', piNonidealText);
generatedTime = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss');
fprintf(fileId, 'Generated        : %s\n\n', char(generatedTime));

fprintf(fileId, 'Column definitions\n');
fprintf(fileId, ['  StartPhase      initial PI phase code, ', ...
    '0..SamplePerSymbol-1\n']);
fprintf(fileId, ['  Locked          pass/fail verdict of the lock criterion ', ...
    'for this start phase\n']);
fprintf(fileId, ['  FreqStateMean   tail-window mean loop frequency state, ', ...
    'code/block\n']);
fprintf(fileId, ['  RotationPeriod  tail-window mean PI rotation period, ', ...
    'block per UI slip\n']);
fprintf(fileId, ['  LockPhase       tail-window eye-phase code, ', ...
    'mod(round(mean(eyePhase)), SPS)\n']);
fprintf(fileId, ['  Stage1Block     first block whose SNR EWMA reaches the ', ...
    'settle threshold\n']);
fprintf(fileId, ['                  (stage-1 mu downshift for the dLev and ', ...
    'FFE loops)\n']);
fprintf(fileId, '  Stage1Phase     eye-phase code at Stage1Block\n');
fprintf(fileId, ['  LockBlock       first block at which the lock criterion ', ...
    'above is satisfied,\n']);
fprintf(fileId, ['                  evaluated with the same detectors and ', ...
    'tolerances as the\n']);
fprintf(fileId, ['                  verdict over a trailing LockWindowBlocks ', ...
    'window. Because the\n']);
fprintf(fileId, ['                  window must be full, this value can never ', ...
    'be below\n']);
fprintf(fileId, '                  LockWindowBlocks.\n');
fprintf(fileId, '  LockPhaseAtBlk  eye-phase code at LockBlock\n');
fprintf(fileId, ['  Stage2Block     block at which the stage-2 mu downshift ', ...
    'actually fired, i.e.\n']);
fprintf(fileId, ['                  the settle -> PVT-track handover of the ', ...
    'dLev and FFE loops.\n']);
fprintf(fileId, ['                  The armed gate is FfeGateCriterion ', ...
    'above:\n']);
fprintf(fileId, ['                    freq-state    the lock criterion ', ...
    'itself (frequencyState mean\n']);
fprintf(fileId, ['                                  within +/-tolerance), so ', ...
    'Stage2Block equals\n']);
fprintf(fileId, ['                                  LockBlock by ', ...
    'construction.\n']);
fprintf(fileId, ['                    center-touch  one raw unwrapped PI code ', ...
    'recurring often\n']);
fprintf(fileId, ['                                  enough to nominate a ', ...
    'centre. A locked phase\n']);
fprintf(fileId, ['                                  sitting off that centre ', ...
    'can keep this gate\n']);
fprintf(fileId, ['                                  from ever latching, ', ...
    'reported as n/a.\n']);
fprintf(fileId, ['  All phase codes are eye phase = unwrapped PI code + drift, ', ...
    'wrapped to one UI.\n\n']);

fprintf(fileId, '%s\n', rule);
printMainHeader(fileId);
fprintf(fileId, '%s\n', rule);
for rowIndex = 1:phaseCount
    printMainRow(fileId, rowIndex, result, freqStateMean(rowIndex), ...
        rotationPeriod(rowIndex), stage1Block(rowIndex), ...
        stage1Phase(rowIndex), lockBlock(rowIndex), ...
        lockPhaseAtBlock(rowIndex), stage2Block(rowIndex));
end
fprintf(fileId, '%s\n\n', rule);

fprintf(fileId, 'Supplementary columns (everything else the CSV carried)\n');
fprintf(fileId, '%s\n', rule);
printSupplementaryHeader(fileId);
fprintf(fileId, '%s\n', rule);
for rowIndex = 1:phaseCount
    printSupplementaryRow(fileId, rowIndex, result, rotationCov(rowIndex));
end
fprintf(fileId, '%s\n\n', rule);

[freqMin, freqMax] = finiteRange(freqStateMean);
[stage1Min, stage1Max] = finiteRange(stage1Block);
[lockMin, lockMax] = finiteRange(lockBlock);
[stage2Min, stage2Max] = finiteRange(stage2Block);
stage2Count = sum(isfinite(stage2Block));
fprintf(fileId, 'Aggregate\n');
fprintf(fileId, '  Locked                : %d / %d\n', ...
    sum(logical(result.LockedFlag)), phaseCount);
fprintf(fileId, ['  AllPhaseLock          : %d       CommonLockPhase : %s   ', ...
    'spread : %s\n'], logical(result.AllPhaseLock), ...
    numberText(result.CommonLockPhase), numberText(result.PhaseSpread));
fprintf(fileId, '  FreqStateMean         : min %s  max %s   (expected %s)\n', ...
    numberText(freqMin), numberText(freqMax), ...
    numberText(result.ExpectedFreqState));
fprintf(fileId, '  Stage1Block           : min %s  max %s   (n/a count %d)\n', ...
    integerText(stage1Min), integerText(stage1Max), ...
    sum(~isfinite(stage1Block)));
fprintf(fileId, '  LockBlock             : min %s  max %s   (n/a count %d)\n', ...
    integerText(lockMin), integerText(lockMax), ...
    sum(~isfinite(lockBlock)));
fprintf(fileId, '  Stage2Block fired     : %d / %d start phases\n\n', ...
    stage2Count, phaseCount);

fprintf(fileId, 'Note on the stage-2 mu downshift\n');
if stage2Count == 0
    fprintf(fileId, ['  The stage-2 gate did not fire for any start phase in this\n', ...
        '  run, so the two-stage mu downshift degenerated to single-stage and the\n', ...
        '  dLev and FFE loops stayed at their settle step size to the end.\n']);
    if ~isFreqStateGate
        fprintf(fileId, ['  This summary is replaying a legacy result whose recorded gate is\n', ...
            '  center-touch. cdr_top no longer drives that detector at all, so the\n', ...
            '  explanation below is historical and applies only to such runs: the\n', ...
            '  center-touch gate was fed the raw unwrapped PI code, it needed one\n', ...
            '  single code value to recur FfeGateMinModeOccurrences times before it\n', ...
            '  would nominate a centre, and a monotonically ramping code never\n', ...
            '  accumulates enough occurrences. No fire was therefore the expected\n', ...
            '  outcome for those runs under a frequency offset.\n']);
    end
else
    fprintf(fileId, ['  The stage-2 gate fired for %d of %d start phases, from block %s\n', ...
        '  through block %s.\n'], stage2Count, phaseCount, ...
        integerText(stage2Min), integerText(stage2Max));
    if isFreqStateGate
        % The gate is the online form of the SAME frequency-state detector,
        % window and tolerances the verdict uses, so it is the frequency-state
        % COMPONENT of the verdict rather than the whole verdict. Where the
        % rotation criterion applies the verdict is a conjunction, hence
        % Stage2Block <= LockBlock and equality is a measured outcome, not a
        % structural identity. Report the measured agreement so the claim is
        % checkable from the file itself.
        comparableMask = isfinite(stage2Block) & isfinite(lockBlock);
        comparableCount = sum(comparableMask);
        agreeCount = sum(stage2Block(comparableMask) == ...
            lockBlock(comparableMask));
        earlierCount = sum(stage2Block(comparableMask) < ...
            lockBlock(comparableMask));
        fprintf(fileId, ['  The armed gate is freq-state: the online form of the same\n', ...
            '  frequency-state detector, trailing window and tolerances the verdict\n', ...
            '  uses. It is therefore the frequency-state COMPONENT of the verdict, not\n', ...
            '  the whole verdict. When RotationCriterionApplicable is 1 the verdict\n', ...
            '  additionally requires detectRotationPeriodLock, so Stage2Block can only\n', ...
            '  be at or before LockBlock; the two coincide exactly when the rotation\n', ...
            '  component is already satisfied at that block.\n']);
        fprintf(fileId, ['  Measured in this run: %d of %d comparable row(s) agree exactly, %d\n', ...
            '  row(s) have Stage2Block strictly earlier than LockBlock.\n'], ...
            agreeCount, comparableCount, earlierCount);
    else
        fprintf(fileId, ['  The armed gate is center-touch, which is independent of the lock\n', ...
            '  criterion: LockBlock is a lock milestone whereas Stage2Block is the\n', ...
            '  downshift event, so the two columns are not the same milestone and need\n', ...
            '  not agree.\n']);
    end
    if stage2Count < phaseCount
        fprintf(fileId, ['  %d start phase(s) never latched the gate (n/a above); those phases\n', ...
            '  ran to the end at the settle step size.\n'], ...
            phaseCount - stage2Count);
    end
end
fprintf(fileId, '%s\n', separator);
end

function txtPath = validateInputs(result, txtPath)
if ~(isstruct(result) && isscalar(result))
    error('write_ppm_lock_summary_txt:InvalidResult', ...
        'result must be a scalar struct.');
end
if isstring(txtPath) && isscalar(txtPath) && ~ismissing(txtPath)
    txtPath = char(txtPath);
end
if ~(ischar(txtPath) && isrow(txtPath) && ~isempty(strtrim(txtPath)))
    error('write_ppm_lock_summary_txt:InvalidTxtPath', ...
        'txtPath must be a nonempty character row or string scalar.');
end
requiredFields = {'FreqOffsetPpm', 'NumBlocks', 'StartPhaseList', ...
    'LockedFlag', 'LockMode', 'LockWindowBlocks', 'ExpectedFreqState', ...
    'ExpectedRotationPeriodBlocks', 'RotationCriterionApplicable', ...
    'SnrSettleThresholdDb', 'SnrSettleAlpha', 'SnrSettleMinBlock', ...
    'SamplePerSymbol', 'IsZeroPpm', 'LockMinEvents', ...
    'LockBandHalfWidth', 'SnrDbTrace', 'UnwrappedPhaseTrace', ...
    'LoopFrequencyStateTrace', 'EyePhaseUnwrappedTrace', 'RunOptions', ...
    'FreqLockDiagnostics', 'RotationLockDiagnostics', 'LockedPhaseCode', ...
    'FreqLockFlag', 'RotationLockFlag', 'SlewSaturatedFlag', ...
    'FirstCaptureBlock', 'SlewDeltaMeanAbs', 'SlewPendingMeanAbs', ...
    'AllPhaseLock', 'CommonLockPhase', 'PhaseSpread'};
missing = requiredFields(~isfield(result, requiredFields));
if ~isempty(missing)
    error('write_ppm_lock_summary_txt:MissingResultField', ...
        'result is missing required field "%s".', missing{1});
end
if ~isPositiveInteger(result.NumBlocks) || ...
        ~isPositiveInteger(result.LockWindowBlocks) || ...
        ~isPositiveInteger(result.SamplePerSymbol)
    error('write_ppm_lock_summary_txt:InvalidResultScalar', ...
        'NumBlocks, LockWindowBlocks, and SamplePerSymbol must be positive integers.');
end
if ~isTextScalar(result.LockMode)
    error('write_ppm_lock_summary_txt:InvalidLockMode', ...
        'result.LockMode must be a character row or string scalar.');
end
phaseCount = numel(result.StartPhaseList);
if phaseCount < 1 || ~isFiniteRealVector(result.StartPhaseList)
    error('write_ppm_lock_summary_txt:InvalidStartPhases', ...
        'result.StartPhaseList must be a nonempty finite real vector.');
end
vectorFields = {'LockedFlag', 'LockedPhaseCode', 'FreqLockFlag', ...
    'RotationLockFlag', 'SlewSaturatedFlag', 'FirstCaptureBlock', ...
    'SlewDeltaMeanAbs', 'SlewPendingMeanAbs'};
for fieldIndex = 1:numel(vectorFields)
    value = result.(vectorFields{fieldIndex});
    if ~(isnumeric(value) || islogical(value)) || ~isreal(value) || ...
            ~isvector(value) || numel(value) ~= phaseCount
        error('write_ppm_lock_summary_txt:InvalidResultVector', ...
            'result.%s must have one real value per start phase.', ...
            vectorFields{fieldIndex});
    end
end
if numel(result.FreqLockDiagnostics) ~= phaseCount || ...
        numel(result.RotationLockDiagnostics) ~= phaseCount
    error('write_ppm_lock_summary_txt:InvalidDiagnostics', ...
        'Lock diagnostics must have one element per start phase.');
end
if ~all(isfield(result.FreqLockDiagnostics, 'MeanValue')) || ...
        ~all(isfield(result.RotationLockDiagnostics, {'PeriodMean', 'PeriodCov'}))
    error('write_ppm_lock_summary_txt:InvalidDiagnostics', ...
        'Lock diagnostics do not contain the required fields.');
end
numBlocks = double(result.NumBlocks);
traceFields = {'SnrDbTrace', 'UnwrappedPhaseTrace', ...
    'LoopFrequencyStateTrace', 'EyePhaseUnwrappedTrace'};
for fieldIndex = 1:numel(traceFields)
    value = result.(traceFields{fieldIndex});
    if ~(isnumeric(value) && isreal(value) && ismatrix(value) && ...
            size(value, 1) >= phaseCount && size(value, 2) >= numBlocks)
        error('write_ppm_lock_summary_txt:InvalidTrace', ...
            'result.%s must cover every start phase and block.', ...
            traceFields{fieldIndex});
    end
end
unwrapped = result.UnwrappedPhaseTrace(1:phaseCount, 1:numBlocks);
frequency = result.LoopFrequencyStateTrace(1:phaseCount, 1:numBlocks);
eyePhase = result.EyePhaseUnwrappedTrace(1:phaseCount, 1:numBlocks);
if any(~isfinite(unwrapped(:))) || any(unwrapped(:) ~= fix(unwrapped(:))) || ...
        any(~isfinite(frequency(:))) || any(~isfinite(eyePhase(:)))
    error('write_ppm_lock_summary_txt:InvalidTrace', ...
        'Lock and phase traces must contain valid finite values.');
end
scalarFields = {'FreqOffsetPpm', 'ExpectedFreqState', ...
    'ExpectedRotationPeriodBlocks', 'SnrSettleThresholdDb', ...
    'SnrSettleAlpha', 'SnrSettleMinBlock', 'LockMinEvents', ...
    'LockBandHalfWidth', 'CommonLockPhase', 'PhaseSpread'};
for fieldIndex = 1:numel(scalarFields)
    value = result.(scalarFields{fieldIndex});
    if ~(isnumeric(value) && isreal(value) && isscalar(value))
        error('write_ppm_lock_summary_txt:InvalidResultScalar', ...
            'result.%s must be a real numeric scalar.', scalarFields{fieldIndex});
    end
end
logicalFields = {'RotationCriterionApplicable', 'IsZeroPpm', 'AllPhaseLock'};
for fieldIndex = 1:numel(logicalFields)
    value = result.(logicalFields{fieldIndex});
    if ~((islogical(value) || isnumeric(value)) && isreal(value) && ...
            isscalar(value) && isfinite(value) && any(double(value) == [0 1]))
        error('write_ppm_lock_summary_txt:InvalidResultScalar', ...
            'result.%s must be a logical scalar.', logicalFields{fieldIndex});
    end
end
if ~(isstruct(result.RunOptions) && isscalar(result.RunOptions))
    error('write_ppm_lock_summary_txt:InvalidRunOptions', ...
        'result.RunOptions must be a scalar struct.');
end
optionFields = {'FreqMeanHalfDiffTol', 'FreqStdTol', 'FreqRateTol', ...
    'RotMinIntervals', 'RotCovTol', 'FfeFreezeMinModeOccurrences', ...
    'FfeFreezeMinEvents', 'FfeFreezeBandHalfWidth'};
missingOptions = optionFields(~isfield(result.RunOptions, optionFields));
if ~isempty(missingOptions)
    error('write_ppm_lock_summary_txt:MissingRunOption', ...
        'result.RunOptions is missing required field "%s".', missingOptions{1});
end
end

function settleBlock = replaySnrSettle(result, rowIndex)
settleBlock = NaN;
snrTrace = reshape(double(result.SnrDbTrace(rowIndex, ...
    1:double(result.NumBlocks))), 1, []);
ewmaDb = NaN;
for blockIndex = 1:numel(snrTrace)
    snrDb = snrTrace(blockIndex);
    if ~isfinite(snrDb)
        continue;
    end
    if isnan(ewmaDb)
        ewmaDb = snrDb;
    else
        alpha = double(result.SnrSettleAlpha);
        ewmaDb = (1 - alpha) * ewmaDb + alpha * snrDb;
    end
    if blockIndex >= double(result.SnrSettleMinBlock) && ...
            ewmaDb >= double(result.SnrSettleThresholdDb)
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
unwrappedTrace = reshape(double(result.UnwrappedPhaseTrace( ...
    rowIndex, 1:numBlocks)), 1, []);
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

frequencyTrace = reshape(double(result.LoopFrequencyStateTrace( ...
    rowIndex, 1:numBlocks)), 1, []);
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
        rotationLocked = true;
    end
    if frequencyLocked && rotationLocked
        lockBlock = blockIndex;
        return;
    end
end
end

function fireBlock = replayStage2Gate(result, rowIndex)
%REPLAYSTAGE2GATE Stage-2 gate block for one start phase.
%
% Runs produced after the gate criterion became switchable record the block
% at which the gate actually fired, so that recorded value is authoritative
% and is used directly. Older result MATs predate the field; for those the
% center-touch gate is replayed, which is correct because center-touch was
% the only criterion those runs could have used. Replaying unconditionally
% would misreport every freq-state run as the center-touch block.
if isfield(result, 'Stage2GateBlock')
    blocks = result.Stage2GateBlock;
    if rowIndex <= numel(blocks)
        fireBlock = double(blocks(rowIndex));
        return;
    end
end

runOptions = result.RunOptions;
monitor = loop_monitor(runOptions.FfeFreezeMinModeOccurrences, ...
    runOptions.FfeFreezeMinEvents, runOptions.FfeFreezeBandHalfWidth, 1);
unwrappedTrace = reshape(double(result.UnwrappedPhaseTrace( ...
    rowIndex, 1:double(result.NumBlocks))), 1, []);
fireBlock = NaN;
for blockIndex = 1:double(result.NumBlocks)
    if monitor.updateFfeGate(unwrappedTrace(blockIndex), blockIndex)
        fireBlock = blockIndex;
        return;
    end
end
end

function text = optionalTextField(result, fieldName, fallbackText)
%OPTIONALTEXTFIELD Read a char/string result field, tolerating absence.
text = fallbackText;
if isfield(result, fieldName)
    value = result.(fieldName);
    if (ischar(value) && isrow(value)) || ...
            (isstring(value) && isscalar(value) && ~ismissing(value))
        candidate = char(value);
        if ~isempty(candidate)
            text = candidate;
        end
    end
end
end

function phaseCode = phaseAtBlock(result, rowIndex, blockIndex)
phaseCode = NaN;
if isfinite(blockIndex)
    phaseCode = mod(round(double(result.EyePhaseUnwrappedTrace( ...
        rowIndex, blockIndex))), double(result.SamplePerSymbol));
end
end

function printMainHeader(fileId)
fprintf(fileId, ['%4s  %10s  %6s  %13s  %14s  %9s  %11s  %11s  ', ...
    '%9s  %14s  %11s\n'], 'idx', 'StartPhase', 'Locked', ...
    'FreqStateMean', 'RotationPeriod', 'LockPhase', 'Stage1Block', ...
    'Stage1Phase', 'LockBlock', 'LockPhaseAtBlk', 'Stage2Block');
end

function printMainRow(fileId, rowIndex, result, freqMean, rotationPeriod, ...
        stage1Block, stage1Phase, lockBlock, lockPhaseAtBlock, stage2Block)
fprintf(fileId, ['%4d  %10s  %6s  %13s  %14s  %9s  %11s  %11s  ', ...
    '%9s  %14s  %11s\n'], rowIndex, ...
    integerText(result.StartPhaseList(rowIndex)), ...
    integerText(result.LockedFlag(rowIndex)), numberText(freqMean), ...
    numberText(rotationPeriod), integerText(result.LockedPhaseCode(rowIndex)), ...
    integerText(stage1Block), integerText(stage1Phase), ...
    integerText(lockBlock), integerText(lockPhaseAtBlock), ...
    integerText(stage2Block));
end

function printSupplementaryHeader(fileId)
fprintf(fileId, ['%4s  %10s  %8s  %12s  %13s  %16s  %11s  ', ...
    '%16s  %18s\n'], 'idx', 'StartPhase', 'FreqLock', 'RotationLock', ...
    'SlewSaturated', 'AcquisitionBlock', 'RotationCov', ...
    'DeltaCodeMeanAbs', 'PendingCodeMeanAbs');
end

function printSupplementaryRow(fileId, rowIndex, result, rotationCov)
fprintf(fileId, ['%4d  %10s  %8s  %12s  %13s  %16s  %11s  ', ...
    '%16s  %18s\n'], rowIndex, ...
    integerText(result.StartPhaseList(rowIndex)), ...
    integerText(result.FreqLockFlag(rowIndex)), ...
    integerText(result.RotationLockFlag(rowIndex)), ...
    integerText(result.SlewSaturatedFlag(rowIndex)), ...
    integerText(result.FirstCaptureBlock(rowIndex)), numberText(rotationCov), ...
    numberText(result.SlewDeltaMeanAbs(rowIndex)), ...
    numberText(result.SlewPendingMeanAbs(rowIndex)));
end

function textValue = integerText(value)
if isnumeric(value) || islogical(value)
    value = double(value);
end
if isreal(value) && isscalar(value) && isfinite(value)
    textValue = sprintf('%.0f', value);
else
    textValue = 'n/a';
end
end

function textValue = numberText(value)
if isnumeric(value) || islogical(value)
    value = double(value);
end
if isreal(value) && isscalar(value) && isfinite(value)
    textValue = sprintf('%.12g', value);
else
    textValue = 'n/a';
end
end

function [minimumValue, maximumValue] = finiteRange(values)
finiteValues = double(values(isfinite(values)));
if isempty(finiteValues)
    minimumValue = NaN;
    maximumValue = NaN;
else
    minimumValue = min(finiteValues);
    maximumValue = max(finiteValues);
end
end

function tf = isPositiveInteger(value)
tf = isnumeric(value) && isreal(value) && isscalar(value) && ...
    isfinite(value) && double(value) >= 1 && double(value) == fix(double(value));
end

function tf = isFiniteRealVector(value)
tf = isnumeric(value) && isreal(value) && isvector(value) && ...
    all(isfinite(value(:)));
end

function tf = isTextScalar(value)
tf = ischar(value) && isrow(value);
if ~tf && isstring(value)
    tf = isscalar(value) && ~ismissing(value);
end
end
