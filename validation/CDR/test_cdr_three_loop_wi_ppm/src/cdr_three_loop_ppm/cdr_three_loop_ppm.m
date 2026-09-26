function result = cdr_three_loop_ppm(varargin)
%CDR_THREE_LOOP_PPM CDR+dlev+CDR-FFE three-loop capture under a frequency offset.
%   RESULT = CDR_THREE_LOOP_PPM(...) drives the configured code-domain
%   cdr_top core exactly like cdr_dlev_cdrffe_sslms_v4, but injects a receiver
%   sampling-clock frequency offset (ppm) at the caller-owned waveform address
%   line. The DSP core stays frequency-offset agnostic: the offset is a slow,
%   block-accumulated integer drift added to the ADC block start index, and the
%   three loops must track it on their own.
%
%   Frequency-offset injection model (scheme A, RX-clock model):
%     - The cached TX waveform is never resampled; one data symbol always
%       occupies exactly SamplesPerSymbol (=128) cached samples.
%     - Sign convention: +FreqOffsetPpm makes one RX UI span
%       SamplesPerSymbol*(1+delta) cached samples, delta = ppm*1e-6, i.e.
%       T_RX = T_TX*(1+delta): the RX clock is SLOWER than the TX symbol rate
%       (the TX data runs ahead of the RX clock). The loop holds the eye by
%       retarding the PI code, so FrequencyState is NEGATIVE for positive ppm.
%       Because 128*(1+delta) is not an integer,
%       the exact cumulative drift is kept in floating point and rounded to the
%       128x sample grid only once, when the block start is formed. Rounding
%       the cumulative value (never the per-block increment) keeps the
%       quantization error bounded to +/-0.5 sample = +/-1/128 UI, on par with
%       the PI resolution. Within one 64-UI ADC block the 64 samples are still
%       taken 128 apart (block-internal drift <= |delta|*128*64 <= 0.82 sample
%       is not modelled); see docs/MODEL_ASSUMPTIONS.md.
%
%   Lock criteria (requirement: switchable, do not delete the zero-offset one):
%     - FreqOffsetPpm == 0: the modal center-touch criterion
%       (detect_pi_center_touch_lock) as in v4 -- the PI code dithers around
%       one fixed code.
%     - FreqOffsetPpm ~= 0: two frequency-domain criteria in loop_monitor:
%       (1) loop_monitor.detectFrequencyStateLock -- the loop integrator
%           frequency state has a constant tail-window mean matching the
%           expected drift rate; (2) loop_monitor.detectRotationPeriodLock --
%           the PI code rotation period (blocks per UI slip) is constant.
%       Both must hold for a start phase to be declared locked.
%
%   Requirement diagnostic (not part of the pass/fail): the "PI actual code
%   minus PI ideal offset-compensated code" trace. The ideal compensating PI
%   code holds the eye phase constant, so the residual is flat once tracked and
%   ramps while still acquiring.

thisFile = mfilename('fullpath');
testDir = fileparts(fileparts(fileparts(thisFile)));
addpath(testDir);
paths = setup_cdr_three_loop_wi_ppm_paths();
cdrValidationDir = paths.CdrValidationDir;
options = parseLoopOptions(varargin{:});
validateOptions(options);

cachePath = fullfile(cdrValidationDir, 'test_cdr', 'result', ...
    options.CosimDir, 'channel_ctle.mat');
assert(isfile(cachePath), ...
    'Run test_channel_ctle_cosim first to generate channel_ctle.mat.');
cacheFile = matfile(cachePath);
samplePerSymbol = double(cacheFile.samplePerSymbol);
numCachedSymbols = double(cacheFile.numSymbols);
assert(samplePerSymbol == 128, ...
    'The cached CTLE waveform must use 128 samples/UI.');
assert(logical(getCachePeriodFlag(cacheFile)), ...
    'The cached CTLE waveform must contain a complete PRBS period.');

adcBlockUi = 64;
% Frequency-offset drift budget (UI) over the whole run. Both the front margin
% (baseUi) and the back margin (uiGuard) absorb the ppm drift plus the loop's
% own acquisition UI slip, so the sampling window never leaves the cache.
driftBudgetUi = ceil(abs(options.FreqOffsetPpm) * 1e-6 * ...
    options.NumBlock * adcBlockUi);

analysisStartUi = 512;
analysisNumUi = options.AnalysisNumUi;
assert(mod(analysisNumUi, adcBlockUi) == 0, ...
    'The fixed analysis segment must contain complete 64-UI blocks.');
assert(analysisStartUi + analysisNumUi <= numCachedSymbols, ...
    'The fixed analysis segment exceeds the CTLE cache.');
segmentFirstSample = analysisStartUi * samplePerSymbol + 1;
segmentLastSample = (analysisStartUi + analysisNumUi) * samplePerSymbol;
ctleSegment = double(cacheFile.ctleOutput( ...
    1, segmentFirstSample:segmentLastSample));
assert(numel(ctleSegment) == analysisNumUi * samplePerSymbol, ...
    'The loaded CTLE analysis segment has the wrong length.');

adcLaneCount = 64;
adcSarPerTah = 8;
adcResolutionBits = 7;
adcFullRange = 4;
adcZeroCode = 2^(adcResolutionBits - 1);
referencePhase = 19;
cdrFfeTapOffset = -2:3;
cdrFfePreTapCount = 2;
cdrFfeTapCount = numel(cdrFfeTapOffset);
cdrFfeMainTapIndex = cdrFfePreTapCount + 1;
cdrFfeEvalOffset = -3:6;
[laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol);

% Offline response only initializes options, truth statistics and plots.
channelCtleImpulse = double(cacheFile.channelCtleImpulse);
channelCtleSymbolPulse = conv(channelCtleImpulse(:), ...
    ones(samplePerSymbol, 1));
channelAdcCursorOffset = ...
    (cdrFfeEvalOffset(1) - cdrFfeTapOffset(end)): ...
    (cdrFfeEvalOffset(end) - cdrFfeTapOffset(1));
analogCursor = samplePulseAtPhase(channelCtleSymbolPulse, ...
    samplePerSymbol, referencePhase, channelAdcCursorOffset);
adcCursorCode = quantizeSamplesWithTiAdc(analogCursor, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    samplePerSymbol, laneToTimeOrder, nominalBlockLength);
adcCursorCodeCentered = adcCursorCode - adcZeroCode;
[cdrFfeCoefficients, cdrFfeDesign] = optimizeCdrFfe( ...
    adcCursorCodeCentered, channelAdcCursorOffset, ...
    cdrFfeTapOffset, cdrFfeEvalOffset);

referenceOutput = processOnePhase(ctleSegment, referencePhase, ...
    samplePerSymbol, adcLaneCount, adcSarPerTah, adcResolutionBits, ...
    adcFullRange, adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, adcBlockUi);
levelCenter = estimatePam4Centers(referenceOutput);
dlevInnerReference = (abs(levelCenter(2)) + abs(levelCenter(3))) / 2;
dlevOuterReference = (abs(levelCenter(1)) + abs(levelCenter(4))) / 2;

switch lower(char(options.FfeInitMode))
    case 'plana'
        ffeBiasVector = zeros(1, cdrFfeTapCount);
        freeTapMask = true(1, cdrFfeTapCount);
        freeTapMask(cdrFfeMainTapIndex) = false;
        ffeBiasVector(freeTapMask) = options.FfeBiasScale;
        ffeInitCoefficients = cdrFfeCoefficients + ffeBiasVector;
    case 'planb'
        ffeInitCoefficients = zeros(1, cdrFfeTapCount);
        ffeInitCoefficients(cdrFfeMainTapIndex) = 1;
    otherwise
        error('cdr_three_loop_ppm:InvalidFfeInitMode', ...
            'FfeInitMode must be ''planA'' or ''planB''.');
end

baseUi = 256 + driftBudgetUi;
uiGuard = 192 + driftBudgetUi;
maxFirstUi = analysisNumUi - adcBlockUi - uiGuard;
numBlocks = floor((maxFirstUi - baseUi) / adcBlockUi);
assert(numBlocks > 60, 'The analysis segment is too short for the loop run.');
if isempty(options.StartPhaseList)
    startPhaseList = 0:options.StartPhaseStep:samplePerSymbol - 1;
else
    startPhaseList = double(options.StartPhaseList(:).');
end
numStartPhase = numel(startPhaseList);

% Frequency-offset sign convention (user-confirmed 2026-09-24):
%   +FreqOffsetPpm advances the cached-waveform read pointer by an extra ppm
%   fraction per UI, i.e. one RX UI spans SamplesPerSymbol*(1+delta) cached
%   samples. Over one block the RX advances 64 RX UI while the address
%   advances 64*128 + drift samples, so
%     64*T_RX = (8192 + drift)*T_TX/128  =>  T_RX = T_TX*(1 + drift/8192),
%   hence T_RX = T_TX*(1+delta): the RX sampling clock is SLOWER than the TX
%   symbol rate by ppm, equivalently the TX data runs ahead of the RX clock.
%   The loop then holds the eye by retarding the PI code (larger code = later
%   phase), so the steady-state FrequencyState is NEGATIVE for positive ppm.
% Units: PI code per block (1 code = 1 sample at 7-bit PI, 128 samples/UI).
driftRatePerBlockCode = options.FreqOffsetPpm * 1e-6 * ...
    samplePerSymbol * adcBlockUi;
isZeroPpm = options.FreqOffsetPpm == 0;
expectedFreqState = -driftRatePerBlockCode;
% PI nonideality. 'ab_constant' is cdr_pi's physical a+b=1 / atan2 model; at
% 7-bit PI and 128 samples/UI its INL is 2.891 LSB pk-pk (1 LSB = 1 code =
% 1 waveform sample), which the integer cache addressing quantizes to three
% distinct sample offsets. 'ideal' restores the exactly-linear table, under
% which the phase-table lookup degenerates to the raw code and the run is
% bit-identical to the pre-nonideality behaviour.
piNonideal = lower(char(options.PiNonideal));
if ~ismember(piNonideal, {'ideal', 'ab_constant'})
    error('cdr_three_loop_ppm:InvalidPiNonideal', ...
        'PiNonideal must be ''ideal'' or ''ab_constant''; got ''%s''.', ...
        piNonideal);
end
% Resolve the second-stage gate criterion before it reaches cdr_top, which
% only accepts a concrete name. 'auto' follows the same zero/nonzero split
% the offline lock verdict uses.
ffeGateCriterion = lower(char(options.FfeGateCriterion));
switch ffeGateCriterion
    case 'auto'
        if isZeroPpm
            ffeGateCriterion = 'center-touch';
        else
            ffeGateCriterion = 'freq-state';
        end
    case {'center-touch', 'freq-state'}
        % Explicit override, used by the A/B comparison.
    otherwise
        error('cdr_three_loop_ppm:InvalidFfeGateCriterion', ...
            ['FfeGateCriterion must be ''auto'', ''center-touch'', or ', ...
            '''freq-state''; got ''%s''.'], ffeGateCriterion);
end
if isZeroPpm
    expectedRotationPeriod = NaN;
else
    expectedRotationPeriod = samplePerSymbol / abs(driftRatePerBlockCode);
end
% Relative rotation-period tolerance (absolute blocks), see RotPeriodTolFrac.
if isempty(options.RotPeriodTol)
    if isZeroPpm
        rotPeriodTolBlocks = Inf;
    else
        rotPeriodTolBlocks = max(2, ...
            options.RotPeriodTolFrac * expectedRotationPeriod);
    end
else
    rotPeriodTolBlocks = options.RotPeriodTol;
end
% Slew utilization: the steady rate the loop must supply divided by the
% per-block PI increment limit. >= 1 means the offset is physically
% untrackable with this MaxDeltaCode, independent of acquisition.
slewUtilization = abs(expectedFreqState) / options.MaxDeltaCode;
% Rotation period a fully slew-saturated loop would show (128 blocks at
% MaxDeltaCode = 1); used only as a reported saturation signature.
saturatedRotationPeriod = samplePerSymbol / options.MaxDeltaCode;
if slewUtilization >= 1
    warning('cdr_three_loop_ppm:SlewLimitExceeded', ...
        ['Required %.4f code/block exceeds MaxDeltaCode = %g (slew ' ...
        'utilization %.3f): %+g ppm is not trackable regardless of ' ...
        'acquisition.'], abs(expectedFreqState), options.MaxDeltaCode, ...
        slewUtilization, options.FreqOffsetPpm);
end
phaseCodeTrace = zeros(numStartPhase, numBlocks);
uiSlipTrace = zeros(numStartPhase, numBlocks);
timingErrorTrace = zeros(numStartPhase, numBlocks);
deltaCodeTrace = zeros(numStartPhase, numBlocks);
loopControlTrace = zeros(numStartPhase, numBlocks);
loopFrequencyTrace = zeros(numStartPhase, numBlocks);
% Block at which the stage-2 (settle -> PVT-track) gate actually fired for
% each start phase; NaN if it never fired over the run.
stage2GateBlock = nan(1, numStartPhase);
% Block at which the stage-1 (capture -> settle) SNR downshift fired. NaN
% when SettleGate is not 'snr', in which case no SNR block exists.
stage1SettleBlock = nan(1, numStartPhase);
loopCodeResidueTrace = zeros(numStartPhase, numBlocks);
loopPendingCodeTrace = zeros(numStartPhase, numBlocks);
unwrappedPhaseTrace = zeros(numStartPhase, numBlocks);
edgeCountTrace = zeros(numStartPhase, numBlocks);
dlevInnerTrace = zeros(numStartPhase, numBlocks);
dlevOuterTrace = zeros(numStartPhase, numBlocks);
dlevThresholdTrace = zeros(numStartPhase, numBlocks);
% Decision-directed eye-quality FOM per block, 10*log10(mean(d^2)/mean(e^2)).
% Diagnostic only: nothing in the loop consumes it yet. It exists to test
% whether a single dB threshold can separate "eye closed" (where the FFE must
% keep its capture step size) from "eye open" (where the mu downshift is safe).
snrDbTrace = nan(numStartPhase, numBlocks);
ffeCoeffTrace = zeros(numStartPhase, numBlocks, cdrFfeTapCount);
driftSampleTrace = zeros(numStartPhase, numBlocks);
lockedPhaseCode = nan(1, numStartPhase);
lockedFlag = false(1, numStartPhase);
freqLockFlag = false(1, numStartPhase);
rotationLockFlag = false(1, numStartPhase);
freqDiagList = cell(1, numStartPhase);
rotationDiagList = cell(1, numStartPhase);
piCenterDiagnostics = cell(1, numStartPhase);
phaseSettleStd = nan(1, numStartPhase);
settleDoneFlag = false(1, numStartPhase);
freqAcqEnableBlock = nan(1, numStartPhase);
slewSaturatedFlag = false(1, numStartPhase);
slewDeltaMeanAbs = nan(1, numStartPhase);
slewPendingMeanAbs = nan(1, numStartPhase);

[~, histogramPhaseIndex] = min(abs(startPhaseList - referencePhase));
histogramTargetSamples = 2048;
histogramOutputHistory = [];
settleBlocks = 30;
piLockWindowBlocks = min(options.LockWindowBlocks, numBlocks);
% The rotation-period criterion needs enough complete PI rotations inside the
% tail window to form RotMinIntervals inter-slip intervals. At small offsets
% one rotation takes 128/|driftRate| blocks, which can exceed the window, so
% the criterion is then NOT APPLICABLE (rather than failed) and the lock
% decision falls back to the frequency-state criterion alone.
if isZeroPpm
    rotationApplicable = false;
else
    rotationApplicable = (piLockWindowBlocks / expectedRotationPeriod) >= ...
        (options.RotMinIntervals + 1);
end
piLockMinEvents = 51;
piLockBandHalfWidth = 3;
captureBandHalfWidth = 6;
dlevSettleStdTolerance = 1.0;
ffeSettleStdTolerance = 0.01;

for startIndex = 1:numStartPhase
    startPhase = startPhaseList(startIndex);
    cfg = cdr_top.defaultConfig();
    cfg.BlockSize = adcBlockUi;
    cfg.SamplesPerSymbol = samplePerSymbol;
    cfg.Detector = 'mmpd';
    cfg.TransitionFilter = double(options.TransitionFilter);
    cfg.PdPolarity = options.Polarity;
    cfg.VoterMode = 'mean';
    cfg.VoterDenominator = 'auto';
    cfg.Kp = options.Kp;
    if options.FreqAcqPonly && ~isZeroPpm
        % Proportional-only acquisition; the integral gain is enabled below
        % once the eye is open (dLev settle).
        cfg.Ki = 0;
    else
        cfg.Ki = options.Ki;
    end
    cfg.FrequencyLimit = options.FrequencyLimit;
    cfg.MaxDeltaCode = options.MaxDeltaCode;
    cfg.PiNumBit = 7;
    cfg.PiNonideal = piNonideal;
    cfg.PiInitialCode = startPhase;
    cfg.DlevInnerInit = options.DlevInnerInit;
    cfg.DlevOuterInit = options.DlevOuterInit;
    cfg.DlevPolarity = options.DlevPolarity;
    cfg.DlevStepSize = options.StepSize;
    cfg.DlevStepSizeSettle = options.StepSizeSettle;
    cfg.DlevSettleWindow = options.DlevSettleWindow;
    cfg.DlevSettleTol = options.DlevSettleTol;
    cfg.DlevStepSizePvtTrack = options.DlevStepSizePvtTrack;
    cfg.SettleGate = options.SettleGate;
    cfg.SnrSettleThresholdDb = options.SnrSettleThresholdDb;
    cfg.SnrSettleAlpha = options.SnrSettleAlpha;
    cfg.SnrSettleMinBlock = options.SnrSettleMinBlock;
    cfg.FfeInitCoefficients = ffeInitCoefficients;
    cfg.FfePreTapCount = cdrFfePreTapCount;
    cfg.FfeStepSize = options.FfeStepSize;
    cfg.FfeStepSizeSettle = options.FfeStepSizeSettle;
    cfg.FfeAdaptEnableMask = options.FfeAdaptEnableMask;
    cfg.FfeGateEnable = logical(options.FfeFreezeEnable);
    cfg.FfeGateMode = lower(char(options.FfeFreezeMode));
    cfg.FfeStepSizePvtTrack = options.FfeStepSizePvtTrack;
    cfg.FfeGateMinModeOccurrences = options.FfeFreezeMinModeOccurrences;
    cfg.FfeGateMinEvents = options.FfeFreezeMinEvents;
    cfg.FfeGateBandHalfWidth = options.FfeFreezeBandHalfWidth;
    cfg.FfeGateStartBlock = 1;
    % Second-stage (settle -> PVT-track) downshift gate. 'center-touch' is
    % the code-domain modal test, which can only fire when the PI code dwells
    % on one code, i.e. at zero frequency offset. 'freq-state' instead uses
    % the loop integrator frequency-state flatness criterion, the online form
    % of the same loop_monitor.detectFrequencyStateLock used for the offline
    % pass/fail verdict, so it remains meaningful at any ppm. The window and
    % tolerances are deliberately the SAME ones the verdict uses, so the gate
    % fires on the criterion the run is judged by rather than on a second,
    % independently tuned rule.
    cfg.FfeGateCriterion = ffeGateCriterion;
    cfg.FfeGateFreqWindowBlocks = piLockWindowBlocks;
    cfg.FfeGateFreqExpectedRate = expectedFreqState;
    cfg.FfeGateFreqMeanHalfDiffTol = options.FreqMeanHalfDiffTol;
    cfg.FfeGateFreqStdTol = options.FreqStdTol;
    cfg.FfeGateFreqRateTol = options.FreqRateTol;
    cfg.FfeGateFreqMinBlock = 1;
    top = cdr_top(cfg);
    % Frequency-acquisition schedule: enable the integral gain once the eye is
    % open. Uses cdr_loop.setGains on the (public-read) loop-filter handle, so
    % no src/CDR module is modified and cdr_top's dLev-settle mu-downshift is
    % left intact.
    kiEnablePending = options.FreqAcqPonly && ~isZeroPpm;

    adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
        adcResolutionBits, adcSarPerTah, samplePerSymbol);
    adcModel.setInputMargin(0);

    appliedDriftSample = zeros(1, numBlocks);
    for sampleBlockIndex = 1:numBlocks + 1
        if sampleBlockIndex <= numBlocks
            [~, sampleUiSlip] = top.getSamplingPhase();
            firstUi = baseUi + (sampleBlockIndex - 1) * adcBlockUi + ...
                sampleUiSlip;
            % In-UI sampling offset in waveform samples. Taking it from the PI
            % PHASE TABLE rather than from the raw code is what makes PI
            % nonideality (INL) observable: the raw code assumes a perfectly
            % linear code->phase map, so a nonideal table would be computed by
            % cdr_pi and then discarded here. Under PiNonideal='ideal' the
            % table is exactly the identity, so round(getLocalIndex()) ==
            % CodeWrapped and this is a bit-exact no-op.
            %
            % The cache is addressed with integer samples, so the offset is
            % rounded. At 128 samples/UI one PI code is one sample, i.e. one
            % LSB, and rounding quantizes INL to +-0.5 LSB. That is adequate
            % for INL of a few LSB pk-pk (6 LSB pk-pk retains ~88% by RMS,
            % 7 distinct offsets) but it annihilates INL below ~0.7 LSB pk-pk.
            sampleOffset = round(top.PhaseInterpolator.getLocalIndex());
            % Scheme-A ppm injection: cumulative floating drift, rounded once.
            driftSample = round(driftRatePerBlockCode * (sampleBlockIndex - 1));
            appliedDriftSample(sampleBlockIndex) = driftSample;
            blockStart = firstUi * samplePerSymbol + sampleOffset + 1 + ...
                driftSample;
            blockStop = blockStart + nominalBlockLength - 1;
            assert(blockStart >= 1 && blockStop <= numel(ctleSegment), ...
                'PI slip plus ppm drift drove the sampling window off the cache.');
            blockWaveform = ctleSegment(blockStart:blockStop);
            physicalCode = adcModel.convertOneBlockFast(blockWaveform, 1);
            centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
            out = top.processBlock(centeredCode);
        else
            out = top.flush();
        end

        if out.HasOutput
            blockIndex = out.BlockIndex;
            phaseCodeTrace(startIndex, blockIndex) = out.SampleCodeWrapped;
            uiSlipTrace(startIndex, blockIndex) = out.SampleUiSlip;
            timingErrorTrace(startIndex, blockIndex) = out.PhaseError;
            deltaCodeTrace(startIndex, blockIndex) = out.DeltaCode;
            loopControlTrace(startIndex, blockIndex) = out.LoopControl;
            loopFrequencyTrace(startIndex, blockIndex) = out.LoopFrequencyState;
            if out.GateTriggered && ~isfinite(stage2GateBlock(startIndex))
                % Record the ACTUAL stage-2 downshift block. Replaying the
                % gate offline would have to assume a criterion, and would be
                % wrong whenever FfeGateCriterion is not the one assumed.
                stage2GateBlock(startIndex) = blockIndex;
            end
            if isfinite(out.SnrSettleBlock) && ...
                    ~isfinite(stage1SettleBlock(startIndex))
                % Stage-1 downshift block, taken from the monitor's own latch
                % rather than re-derived from the SNR trace.
                stage1SettleBlock(startIndex) = out.SnrSettleBlock;
            end
            loopCodeResidueTrace(startIndex, blockIndex) = out.LoopCodeResidue;
            loopPendingCodeTrace(startIndex, blockIndex) = out.LoopPendingCode;
            unwrappedPhaseTrace(startIndex, blockIndex) = out.UnwrappedCode;
            edgeCountTrace(startIndex, blockIndex) = sum(out.ValidTransition);
            dlevInnerTrace(startIndex, blockIndex) = out.DlevInner;
            dlevOuterTrace(startIndex, blockIndex) = out.DlevOuter;
            dlevThresholdTrace(startIndex, blockIndex) = out.DlevThreshold;
            snrDbTrace(startIndex, blockIndex) = ...
                blockDecisionSnrDb(out.Decision, out.SliceError);
            ffeCoeffTrace(startIndex, blockIndex, :) = ...
                reshape(out.FfeCoefficients, 1, 1, cdrFfeTapCount);
            driftSampleTrace(startIndex, blockIndex) = ...
                appliedDriftSample(blockIndex);
            if startIndex == histogramPhaseIndex && out.FfeAdaptationCalculated
                histogramOutputHistory = ...
                    [histogramOutputHistory, out.FfeOutput]; %#ok<AGROW>
            end
            % Enable the integral gain once the eye is open (dLev settle),
            % completing the proportional-only frequency-acquisition schedule.
            if kiEnablePending && out.SettleDone
                top.LoopFilter.setGains(options.Kp, options.Ki);
                kiEnablePending = false;
                freqAcqEnableBlock(startIndex) = blockIndex;
            end
        end
    end

    topState = top.getState();
    settleDoneFlag(startIndex) = topState.SettleDone;

    settleWindow = unwrappedPhaseTrace(startIndex, end - settleBlocks + 1:end);
    phaseSettleStd(startIndex) = std(settleWindow);

    if isZeroPpm
        [lockedFlag(startIndex), lockedPhaseCode(startIndex), ...
            piCenterDiagnostics{startIndex}] = detect_pi_center_touch_lock( ...
            unwrappedPhaseTrace(startIndex, :), piLockWindowBlocks, ...
            piLockMinEvents, piLockBandHalfWidth, samplePerSymbol);
        freqDiagList{startIndex} = struct('MeanValue', NaN, ...
            'MeanHalfDiff', NaN, 'TailStd', NaN, 'RateError', NaN);
        rotationDiagList{startIndex} = struct('PeriodMean', NaN, ...
            'PeriodStd', NaN, 'PeriodCov', NaN, 'EventCount', 0);
    else
        [freqLockFlag(startIndex), freqDiag] = ...
            loop_monitor.detectFrequencyStateLock( ...
            loopFrequencyTrace(startIndex, :), piLockWindowBlocks, ...
            expectedFreqState, options.FreqMeanHalfDiffTol, ...
            options.FreqStdTol, options.FreqRateTol);
        [rotationLockFlag(startIndex), rotationDiag] = ...
            loop_monitor.detectRotationPeriodLock( ...
            unwrappedPhaseTrace(startIndex, :), piLockWindowBlocks, ...
            samplePerSymbol, options.RotMinIntervals, options.RotCovTol, ...
            expectedRotationPeriod, rotPeriodTolBlocks);
        % Slew-saturation guard. A loop pinned at MaxDeltaCode, or carrying a
        % persistent clipped-code backlog, is not tracking even if its
        % frequency state and rotation period look constant.
        tailIndex = (numBlocks - piLockWindowBlocks + 1):numBlocks;
        slewDeltaMeanAbs(startIndex) = ...
            mean(abs(deltaCodeTrace(startIndex, tailIndex)));
        slewPendingMeanAbs(startIndex) = ...
            mean(abs(loopPendingCodeTrace(startIndex, tailIndex)));
        slewSaturatedFlag(startIndex) = ...
            slewDeltaMeanAbs(startIndex) >= ...
            options.SlewSatDeltaFrac * options.MaxDeltaCode || ...
            slewPendingMeanAbs(startIndex) >= options.SlewSatPendingTol;
        if rotationApplicable
            lockedFlag(startIndex) = freqLockFlag(startIndex) && ...
                rotationLockFlag(startIndex) && ...
                ~slewSaturatedFlag(startIndex);
        else
            % Too few PI rotations fit the tail window at this offset, so the
            % rotation-period criterion is not applicable; the frequency-state
            % criterion alone decides (still gated by slew saturation).
            lockedFlag(startIndex) = freqLockFlag(startIndex) && ...
                ~slewSaturatedFlag(startIndex);
        end
        freqDiagList{startIndex} = freqDiag;
        rotationDiagList{startIndex} = rotationDiag;
        eyeTail = unwrappedPhaseTrace(startIndex, end - piLockWindowBlocks + 1:end) + ...
            driftSampleTrace(startIndex, end - piLockWindowBlocks + 1:end);
        lockedPhaseCode(startIndex) = mod(round(mean(eyeTail)), samplePerSymbol);
        piCenterDiagnostics{startIndex} = struct('CenterUnwrapped', ...
            round(mean(eyeTail)), 'FinalCount', NaN);
    end

    if isZeroPpm
        modeText = 'center-touch';
        lockDetail = sprintf('events=%g', ...
            piCenterDiagnostics{startIndex}.FinalCount);
    else
        modeText = 'freq+rotation';
        lockDetail = sprintf('freqMean=%.4g(exp%.4g) cov=%.3g period=%.4g', ...
            freqDiagList{startIndex}.MeanValue, expectedFreqState, ...
            rotationDiagList{startIndex}.PeriodCov, ...
            rotationDiagList{startIndex}.PeriodMean);
    end
    fprintf(['Start phase %3d/%d [%s]: locked=%d (freq=%d rot=%d sat=%d), ' ...
        'eye phase code=%g, %s, dLev=[%.2f %.2f].\n'], startPhase, ...
        samplePerSymbol, modeText, lockedFlag(startIndex), ...
        freqLockFlag(startIndex), rotationLockFlag(startIndex), ...
        slewSaturatedFlag(startIndex), lockedPhaseCode(startIndex), ...
        lockDetail, dlevInnerTrace(startIndex, end), ...
        dlevOuterTrace(startIndex, end));
end

% Eye-phase (physical sampling position in the eye grid) = PI unwrapped code
% plus the injected integer drift. Constant once tracked, for both 0 ppm
% (drift 0) and ppm cases; used for cross-start consistency and requirement 4.
eyePhaseUnwrappedTrace = unwrappedPhaseTrace + driftSampleTrace;
driftExactTrace = repmat(driftRatePerBlockCode * (0:numBlocks - 1), ...
    numStartPhase, 1);

% First-capture (acquisition) block per start: last exit from the eye-phase
% band around the tracked center, then argmax over locked rows.
firstCaptureBlock = nan(1, numStartPhase);
piTrackingErrorTrace = zeros(numStartPhase, numBlocks);
for startIndex = 1:numStartPhase
    tailWindow = eyePhaseUnwrappedTrace(startIndex, ...
        end - piLockWindowBlocks + 1:end);
    centerC = mean(tailWindow);
    residual = eyePhaseUnwrappedTrace(startIndex, :) - centerC;
    piTrackingErrorTrace(startIndex, :) = residual;
    outside = find(abs(residual) > captureBandHalfWidth, 1, 'last');
    if isempty(outside)
        firstCaptureBlock(startIndex) = 1;
    elseif outside < numBlocks
        firstCaptureBlock(startIndex) = outside + 1;
    else
        firstCaptureBlock(startIndex) = NaN;
    end
end
eligible = find(lockedFlag & isfinite(firstCaptureBlock));
slowestIndex = NaN;
if ~isempty(eligible)
    [~, position] = max(firstCaptureBlock(eligible));
    slowestIndex = eligible(position);
end
selectionFlag = isfinite(slowestIndex);
selectedStartPhase = NaN;
selectedCaptureBlock = NaN;
if selectionFlag
    selectedStartPhase = startPhaseList(slowestIndex);
    selectedCaptureBlock = firstCaptureBlock(slowestIndex);
end

% Preserve the locked-only selection for the result fields before the plot
% selection may reassign selectedStartPhase/selectedCaptureBlock to a worst
% failing row for the diagnostic figures.
slowestLockedStartPhase = selectedStartPhase;
slowestLockedCaptureBlock = selectedCaptureBlock;

% Plotting selection. Prefer the slowest locked capture; when nothing locked
% (e.g. -100 ppm cold start) fall back to the WORST failing start so the
% per-start diagnostic figures still render for debugging. "Worst" for a
% frequency offset is the row whose frequency-state tail mean is furthest from
% the expected tracking rate; at 0 ppm it is the largest tail phase std.
plotIndex = slowestIndex;
plotIsLocked = selectionFlag;
if ~selectionFlag
    if isZeroPpm
        [~, plotIndex] = max(phaseSettleStd);
    else
        freqMeanAll = cellfun(@(diagnostic) diagnostic.MeanValue, freqDiagList);
        [~, plotIndex] = max(abs(freqMeanAll - expectedFreqState));
    end
    selectedStartPhase = startPhaseList(plotIndex);
    selectedCaptureBlock = firstCaptureBlock(plotIndex);
end
plotSelected = isfinite(plotIndex);
% Mu-downshift milestones for the plotted start phase. These are the two
% events that change the loop step sizes, so marking them makes the kinks in
% the convergence traces attributable:
%   stage 1 = capture -> settle, gated by the SNR-EWMA threshold
%   stage 2 = settle -> PVT-track, gated by FfeGateCriterion
% Both are NaN-safe: a milestone that never happened is simply not drawn.
selectedStage1Block = NaN;
selectedStage2Block = NaN;
if plotSelected
    selectedStage1Block = stage1SettleBlock(plotIndex);
    selectedStage2Block = stage2GateBlock(plotIndex);
end
if plotIsLocked
    plotRowTag = 'slowest locked first-capture';
else
    plotRowTag = 'WORST FAILING start (not locked)';
end

lockedCodeList = lockedPhaseCode(lockedFlag);
if isempty(lockedCodeList)
    commonLockPhase = NaN;
    phaseSpread = NaN;
else
    circularSeparation = abs(mod(lockedCodeList(:) - ...
        lockedCodeList(:).' + samplePerSymbol / 2, samplePerSymbol) - ...
        samplePerSymbol / 2);
    [~, medoidIndex] = min(sum(circularSeparation, 2));
    medoidCode = lockedCodeList(medoidIndex);
    liftedLockedCode = medoidCode + mod(lockedCodeList - medoidCode + ...
        samplePerSymbol / 2, samplePerSymbol) - samplePerSymbol / 2;
    commonLockPhase = mod(floor(median(liftedLockedCode) + 0.5), ...
        samplePerSymbol);
    phaseSpread = max(liftedLockedCode) - min(liftedLockedCode);
end
commonDistance = abs(mod(lockedPhaseCode - commonLockPhase + ...
    samplePerSymbol / 2, samplePerSymbol) - samplePerSymbol / 2);
% All-phase consistency band. Under a frequency offset the injected +/-1..2
% code rounding plus the rotating limit cycle widen the per-start locked eye
% phase versus the 0 ppm dither, so the ppm band is looser than the 0 ppm one.
if isZeroPpm
    allPhaseBand = 3;
else
    allPhaseBand = 16;
end
allPhaseLock = all(lockedFlag) && all(commonDistance <= allPhaseBand);

dlevInnerFinal = dlevInnerTrace(:, end).';
dlevOuterFinal = dlevOuterTrace(:, end).';
dlevInnerSpread = max(dlevInnerFinal) - min(dlevInnerFinal);
dlevOuterSpread = max(dlevOuterFinal) - min(dlevOuterFinal);
dlevConsistent = dlevInnerSpread <= 2 * dlevSettleStdTolerance && ...
    dlevOuterSpread <= 2 * dlevSettleStdTolerance;
dlevInnerTruthError = mean(dlevInnerFinal) - dlevInnerReference;
dlevOuterTruthError = mean(dlevOuterFinal) - dlevOuterReference;

ffeFinalCoefficients = reshape(ffeCoeffTrace(:, end, :), ...
    numStartPhase, cdrFfeTapCount);
ffeCoeffSpread = max(ffeFinalCoefficients, [], 1) - ...
    min(ffeFinalCoefficients, [], 1);
ffeCoeffMean = mean(ffeFinalCoefficients, 1);
ffeConsistent = max(ffeCoeffSpread) <= 2 * ffeSettleStdTolerance;
if any(lockedFlag)
    evalPhase = commonLockPhase;
else
    evalPhase = referencePhase;
end
displayEvalOffset = -3:8;
displayRegressor = buildPathRegressor(channelCtleSymbolPulse, ...
    samplePerSymbol, evalPhase, displayEvalOffset, cdrFfeTapOffset, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    laneToTimeOrder, nominalBlockLength, adcZeroCode);
displayOutputCursor = reshape(displayRegressor * ffeCoeffMean(:), 1, []);
displayNormalizedCursor = displayOutputCursor / ...
    displayOutputCursor(displayEvalOffset == 0);
if numel(histogramOutputHistory) >= histogramTargetSamples
    histogramSamples = histogramOutputHistory( ...
        end - histogramTargetSamples + 1:end);
else
    histogramSamples = histogramOutputHistory;
end

ppmTag = sprintf('%s%d', ternaryChar(options.FreqOffsetPpm >= 0, 'p', 'm'), ...
    round(abs(options.FreqOffsetPpm)));
resultDir = fullfile(testDir, 'result', ...
    sprintf('cdr_three_loop_ppm_%s', ppmTag));
if ~isempty(options.ResultDir)
    resultDir = char(options.ResultDir);
end
if options.SaveOutputs && ~exist(resultDir, 'dir')
    mkdir(resultDir);
end
convergenceFigurePath = fullfile(resultDir, 'cdr_phase_convergence.fig');
lockSummaryFigurePath = fullfile(resultDir, 'cdr_locked_phase_vs_start_phase.fig');
dlevConvergenceFigurePath = fullfile(resultDir, 'dlev_convergence.fig');
ffeConvergenceFigurePath = fullfile(resultDir, 'cdr_ffe_convergence.fig');
ffeHistogramFigurePath = fullfile(resultDir, 'cdr_ffe_output_histogram.fig');
totalPathResponseFigurePath = fullfile(resultDir, ...
    'cdr_total_path_ui_response.fig');
loopDitherFigurePath = fullfile(resultDir, 'cdr_loop_freq_state.fig');
trackingErrorFigurePath = fullfile(resultDir, 'cdr_pi_tracking_error.fig');
resultMatPath = fullfile(resultDir, 'cdr_three_loop_ppm_result.mat');

if options.SaveOutputs
    blockAxis = 1:numBlocks;
    selectedModalPhaseCode = NaN;
    if plotSelected
        selectedModalPhaseCode = lockedPhaseCode(plotIndex);
    end
    dlevInnerInit = options.DlevInnerInit;
    dlevOuterInit = options.DlevOuterInit;
    ffeInitModeLabel = lower(char(options.FfeInitMode));
    ffeAdaptEnableMask = logical(options.FfeAdaptEnableMask);

    % Figure 1: PI code (wrapped) convergence of the selected start (slowest
    % locked capture, or the worst failing start when nothing locked).
    % Under a frequency offset the wrapped code is a rotating sawtooth whose
    % period is the tracked rotation period; 0 ppm collapses to a flat line.
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
    if plotSelected
        plot(blockAxis, phaseCodeTrace(plotIndex, :), ...
            'Color', [0.10 0.40 0.80], 'LineWidth', 0.9);
        hold on;
        yline(selectedModalPhaseCode, 'k--', ...
            sprintf('eye phase code %g', selectedModalPhaseCode), ...
            'LineWidth', 1.2);
        if isfinite(selectedCaptureBlock)
            xline(selectedCaptureBlock, 'r--', ...
                sprintf('acquisition block %g', selectedCaptureBlock), ...
                'LineWidth', 1.2);
        end
        drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
            options.SnrSettleThresholdDb, ffeGateCriterion, true);
        hold off; grid on;
        xlim([blockAxis(1) blockAxis(end)]);
        ylim([0 samplePerSymbol - 1]);
        xlabel('CDR Block Index (64 UI per block)');
        ylabel('PI Sampling Phase Code (wrapped, sample index)');
        title(sprintf(['Triple-loop CDR wrapped PI code @ %+g ppm | %s: start phase %g, ' ...
            'expected rotation period %.4g blocks/UI'], options.FreqOffsetPpm, ...
            plotRowTag, selectedStartPhase, expectedRotationPeriod));
    else
        axis off;
        text(0.5, 0.5, 'No start phase available to plot.', ...
            'Units', 'normalized', 'HorizontalAlignment', 'center', ...
            'FontWeight', 'bold');
        title(sprintf('Triple-loop CDR PI code @ %+g ppm', ...
            options.FreqOffsetPpm));
    end
    saveFigureResilient(fig, convergenceFigurePath); close(fig);

    % Figure 2: locked eye phase code vs start phase (blue pass, red fail).
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 620]);
    plot(startPhaseList, lockedPhaseCode, '-', 'Color', [0.65 0.65 0.65], ...
        'LineWidth', 1.0);
    hold on;
    plot(startPhaseList(lockedFlag), lockedPhaseCode(lockedFlag), 'bo', ...
        'LineWidth', 1.3, 'MarkerFaceColor', 'b');
    plot(startPhaseList(~lockedFlag), lockedPhaseCode(~lockedFlag), 'rx', ...
        'LineWidth', 1.5, 'MarkerSize', 8);
    if isfinite(commonLockPhase)
        yline(commonLockPhase, 'k--', ...
            sprintf('common eye phase %g', commonLockPhase), 'LineWidth', 1.2);
    end
    hold off; grid on;
    xlim([min(startPhaseList) - 0.5 max(startPhaseList) + 0.5]);
    xlabel('Initial Sampling Phase Code');
    ylabel('Tracked eye phase code (last window)');
    title(sprintf(['Eye Phase vs Start Phase @ %+g ppm (%d/%d locked, ' ...
        'all-phase lock = %d, spread = %g code)'], options.FreqOffsetPpm, ...
        sum(lockedFlag), numStartPhase, allPhaseLock, phaseSpread));
    saveFigureResilient(fig, lockSummaryFigurePath); close(fig);

    % Figure 3: dLev convergence of the selected start (worst failing when
    % nothing locked).
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
    if plotSelected
        plot(blockAxis, dlevOuterTrace(plotIndex, :), ...
            'Color', [0.10 0.40 0.80], 'LineWidth', 1.0);
        hold on;
        plot(blockAxis, dlevInnerTrace(plotIndex, :), ...
            'Color', [0.85 0.35 0.10], 'LineWidth', 1.0);
        yline(dlevOuterReference, 'r--', ...
            sprintf('outer ref %.2f', dlevOuterReference), 'LineWidth', 1.2);
        yline(dlevInnerReference, 'r:', ...
            sprintf('inner ref %.2f', dlevInnerReference), 'LineWidth', 1.2);
        yline(dlevOuterInit, 'k--', ...
            sprintf('outer init %.2f', dlevOuterInit), 'LineWidth', 1.0);
        yline(dlevInnerInit, 'k:', ...
            sprintf('inner init %.2f', dlevInnerInit), 'LineWidth', 1.0);
        if isfinite(selectedCaptureBlock)
            xline(selectedCaptureBlock, 'r--', ...
                sprintf('acquisition block %g', selectedCaptureBlock), ...
                'LineWidth', 1.2);
        end
        drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
            options.SnrSettleThresholdDb, ffeGateCriterion, true);
        hold off; grid on;
        xlim([blockAxis(1) blockAxis(end)]);
        xlabel('CDR Block Index (64 UI per block)');
        ylabel('Adapted dLev (code domain)');
        title(sprintf(['dLev Trace @ %+g ppm | %s: start phase %g, ' ...
            'mu=%.4g->%.4g->%.4g (capture->settle->PVT)'], ...
            options.FreqOffsetPpm, plotRowTag, selectedStartPhase, ...
            options.StepSize, options.StepSizeSettle, ...
            options.DlevStepSizePvtTrack));
    else
        axis off;
        text(0.5, 0.5, 'No start phase available to plot.', 'Units', ...
            'normalized', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('dLev Trace: no data');
    end
    saveFigureResilient(fig, dlevConvergenceFigurePath); close(fig);

    % Figure 4: CDR FFE coefficient convergence of the selected start.
    freeTapIndexList = find(ffeAdaptEnableMask);
    numFreeTap = numel(freeTapIndexList);
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 720]);
    if plotSelected
        tiledLayout = tiledlayout(fig, numFreeTap, 1, ...
            'TileSpacing', 'compact', 'Padding', 'compact');
        for freeIdx = 1:numFreeTap
            tapIndex = freeTapIndexList(freeIdx);
            nexttile(tiledLayout);
            tapTrace = reshape(ffeCoeffTrace(plotIndex, :, tapIndex), ...
                1, numBlocks);
            plot(blockAxis, tapTrace, 'Color', [0.10 0.40 0.80], 'LineWidth', 0.9);
            hold on;
            yline(cdrFfeCoefficients(tapIndex), 'k--', ...
                sprintf('offline %.4f', cdrFfeCoefficients(tapIndex)), ...
                'LineWidth', 1.1);
            if isfinite(selectedCaptureBlock)
                xline(selectedCaptureBlock, 'r--', 'LineWidth', 1.0);
            end
            drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
                options.SnrSettleThresholdDb, ffeGateCriterion, false);
            hold off; grid on;
            xlim([blockAxis(1) blockAxis(end)]);
            thisOffset = cdrFfeTapOffset(tapIndex);
            if thisOffset < 0
                tapName = sprintf('pre%d tap', -thisOffset);
            elseif thisOffset > 0
                tapName = sprintf('post%d tap', thisOffset);
            else
                tapName = 'main tap';
            end
            ylabel(sprintf('%s (offset %+d)', tapName, thisOffset));
            if freeIdx == 1
                title(tiledLayout, sprintf(['CDR FFE Trace @ %+g ppm | %s: start ' ...
                    'phase %g, %s, mu=%.3g->%.3g'], options.FreqOffsetPpm, ...
                    plotRowTag, selectedStartPhase, ffeInitModeLabel, ...
                    options.FfeStepSize, options.FfeStepSizeSettle));
            end
            if freeIdx == numFreeTap
                xlabel('CDR Block Index (64 UI per block)');
            end
        end
    else
        axis off;
        text(0.5, 0.5, 'No start phase available to plot.', 'Units', ...
            'normalized', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('CDR FFE Trace: no data');
    end
    saveFigureResilient(fig, ffeConvergenceFigurePath); close(fig);

    % Figure 5: converged CDR FFE output histogram (rotating phase under ppm).
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 620]);
    ax = axes(fig);
    if ~isempty(histogramSamples)
        histogram(ax, histogramSamples, 'BinMethod', 'integers', ...
            'FaceColor', [0.2 0.4 0.8], 'EdgeColor', 'none');
        hold(ax, 'on');
        [hRefLine, hConvLine] = addDlevHistogramReferenceLines(ax, ...
            levelCenter, dlevInnerFinal(histogramPhaseIndex), ...
            dlevOuterFinal(histogramPhaseIndex));
        legend(ax, [hRefLine hConvLine], ...
            {'offline-optimal reference level', 'online-converged dlev level'}, ...
            'Location', 'best', 'AutoUpdate', 'off', 'FontSize', 8);
        hold(ax, 'off');
    end
    grid(ax, 'on');
    xlabel(ax, 'Converged CDR FFE Output (code domain)');
    ylabel(ax, 'Sample Count');
    title(ax, sprintf(['Converged CDR FFE Output Histogram @ %+g ppm ' ...
        '(start phase %g, %d samples, phase rotates under offset)'], ...
        options.FreqOffsetPpm, startPhaseList(histogramPhaseIndex), ...
        numel(histogramSamples)));
    saveFigureResilient(fig, ffeHistogramFigurePath); close(fig);

    % Figure 6: total-path unit-UI response evaluated at the tracked eye phase.
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 620]);
    stemHandle = stem(displayEvalOffset, displayNormalizedCursor, 'filled', ...
        'LineWidth', 1.3, 'Color', [0.2 0.4 0.8]);
    stemHandle.MarkerSize = 6;
    hold on;
    stem(0, displayNormalizedCursor(displayEvalOffset == 0), 'filled', ...
        'LineWidth', 1.6, 'Color', [0.85 0.2 0.2], 'MarkerSize', 8);
    yline(0, 'k--', 'pre1/post1 target 0 (SS-LMS ISI-null)', 'LineWidth', 1.0);
    for cursorIdx = 1:numel(displayEvalOffset)
        text(displayEvalOffset(cursorIdx), displayNormalizedCursor(cursorIdx), ...
            sprintf('%.3f', displayNormalizedCursor(cursorIdx)), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
            'FontSize', 7);
    end
    hold off; grid on;
    xlim([displayEvalOffset(1) - 0.5, displayEvalOffset(end) + 0.5]);
    xticks(displayEvalOffset);
    xlabel('Cursor Offset (UI, 0 = main)');
    ylabel('Normalized Total-Path Response (main = 1)');
    title(sprintf(['Total-Path Unit-UI Response @ %+g ppm | evaluated @ ' ...
        'eye phase %g (S-curve ref %d)'], options.FreqOffsetPpm, evalPhase, ...
        referencePhase));
    saveFigureResilient(fig, totalPathResponseFigurePath); close(fig);

    % Figure 7: loop frequency state (the ppm lock observable) plus loop
    % control and code residue. The tail-window mean frequency state equals the
    % steady timing rate the loop supplies to track the offset.
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 780]);
    if plotSelected
        freqLayout = tiledlayout(fig, 3, 1, ...
            'TileSpacing', 'compact', 'Padding', 'compact');
        tailWindow = max(1, numBlocks - piLockWindowBlocks + 1):numBlocks;
        freq = loopFrequencyTrace(plotIndex, :);
        ctrl = loopControlTrace(plotIndex, :);
        resid = loopCodeResidueTrace(plotIndex, :);
        tailMeanFreq = mean(freq(tailWindow));

        nexttile(freqLayout);
        plot(blockAxis, freq, 'Color', [0.85 0.35 0.10], 'LineWidth', 0.9);
        hold on;
        yline(tailMeanFreq, 'r--', ...
            sprintf('tail mean %.4g code/block', tailMeanFreq), 'LineWidth', 1.2);
        yline(expectedFreqState, 'k--', ...
            sprintf('expected %.4g code/block', expectedFreqState), ...
            'LineWidth', 1.0);
        if isfinite(selectedCaptureBlock)
            xline(selectedCaptureBlock, 'r--', 'LineWidth', 1.0);
        end
        drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
            options.SnrSettleThresholdDb, ffeGateCriterion, false);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylabel('FrequencyState (code/block)');
        title(freqLayout, sprintf(['Loop frequency state @ %+g ppm | %s: start ' ...
            'phase %g | tail mean %.4g vs expected %.4g code/block'], ...
            options.FreqOffsetPpm, plotRowTag, selectedStartPhase, tailMeanFreq, ...
            expectedFreqState));

        nexttile(freqLayout);
        plot(blockAxis, ctrl, 'Color', [0.10 0.40 0.80], 'LineWidth', 0.7);
        hold on; yline(0, 'k--', 'LineWidth', 1.0);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylabel('LoopControl (code/block)');

        nexttile(freqLayout);
        plot(blockAxis, resid, 'Color', [0.2 0.6 0.3], 'LineWidth', 0.7);
        hold on; yline(0, 'k--', 'LineWidth', 1.0);
        hold off; grid on; xlim([blockAxis(1) blockAxis(end)]);
        ylim([-1 1]);
        ylabel('CodeResidue (sub-code)');
        xlabel('CDR Block Index (64 UI per block)');
    else
        axis off;
        text(0.5, 0.5, 'No start phase available to plot.', 'Units', ...
            'normalized', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        title('Loop frequency state: no data');
    end
    saveFigureResilient(fig, loopDitherFigurePath); close(fig);

    % Figure 8 (requirement 4, diagnostic only, not a lock criterion):
    % PI actual code minus the ideal offset-compensated code. The ideal PI code
    % holds the eye phase constant, so this residual is flat once tracked and a
    % ramp while still acquiring. Selected start bold; all starts faint.
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
    hold on;
    for startIndex = 1:numStartPhase
        plot(blockAxis, piTrackingErrorTrace(startIndex, :), ...
            'Color', [0.75 0.80 0.88], 'LineWidth', 0.5);
    end
    if plotSelected
        plot(blockAxis, piTrackingErrorTrace(plotIndex, :), ...
            'Color', [0.10 0.40 0.80], 'LineWidth', 1.1);
        if isfinite(selectedCaptureBlock)
            xline(selectedCaptureBlock, 'r--', ...
                sprintf('acquisition block %g', selectedCaptureBlock), ...
                'LineWidth', 1.2);
        end
        drawStageMarkers(selectedStage1Block, selectedStage2Block, ...
            options.SnrSettleThresholdDb, ffeGateCriterion, true);
    end
    yline(0, 'k--', 'ideal offset-compensated PI code', 'LineWidth', 1.0);
    yline(captureBandHalfWidth, 'k:', 'LineWidth', 0.8);
    yline(-captureBandHalfWidth, 'k:', 'LineWidth', 0.8);
    hold off; grid on;
    xlim([blockAxis(1) blockAxis(end)]);
    xlabel('CDR Block Index (64 UI per block)');
    ylabel('PI actual code - ideal offset code (sample)');
    title(sprintf(['PI Tracking Error vs Ideal Offset Code @ %+g ppm | %s ' ...
        '(diagnostic only; flat = tracked, ramp = acquiring)'], ...
        options.FreqOffsetPpm, plotRowTag));
    saveFigureResilient(fig, trackingErrorFigurePath); close(fig);
end

result = struct();
result.RunnerName = 'cdr_three_loop_ppm';
result.CachePath = cachePath;
result.FreqOffsetPpm = options.FreqOffsetPpm;
result.DriftRatePerBlockCode = driftRatePerBlockCode;
result.ExpectedFreqState = expectedFreqState;
result.ExpectedRotationPeriodBlocks = expectedRotationPeriod;
result.DriftBudgetUi = driftBudgetUi;
result.IsZeroPpm = isZeroPpm;
result.LockMode = ternaryChar(isZeroPpm, 'center-touch', 'freq+rotation');
result.RotationCriterionApplicable = rotationApplicable;
result.RotPeriodTolBlocks = rotPeriodTolBlocks;
result.SlewUtilization = slewUtilization;
result.SaturatedRotationPeriodBlocks = saturatedRotationPeriod;
result.SlewSaturatedFlag = slewSaturatedFlag;
result.SlewDeltaMeanAbs = slewDeltaMeanAbs;
result.SlewPendingMeanAbs = slewPendingMeanAbs;
result.AnalysisStartUi = analysisStartUi;
result.AnalysisNumUi = analysisNumUi;
result.SamplePerSymbol = samplePerSymbol;
% Sampling-address descriptors. Saved so an offline consumer can rebuild the
% per-block cached-waveform address without re-deriving constants from the
% runner source (see helpers/build_ppm_eye_set.m).
result.AdcBlockUi = adcBlockUi;
result.CdrFfePreTapCount = cdrFfePreTapCount;
result.ReferencePhase = referencePhase;
result.EvalPhase = evalPhase;
result.AdcResolutionBits = adcResolutionBits;
result.AdcFullRange = [-adcFullRange adcFullRange];
result.CdrFfeCoefficients = cdrFfeCoefficients;
result.CdrFfeDesign = cdrFfeDesign;
result.CdrFfeTapOffset = cdrFfeTapOffset;
result.CdrFfeMainTapIndex = cdrFfeMainTapIndex;
result.FfeInitMode = lower(char(options.FfeInitMode));
result.FfeInitCoefficients = ffeInitCoefficients;
result.FfeStepSize = options.FfeStepSize;
result.FfeStepSizeSettle = options.FfeStepSizeSettle;
result.SettleGate = options.SettleGate;
result.SnrSettleThresholdDb = options.SnrSettleThresholdDb;
result.SnrSettleAlpha = options.SnrSettleAlpha;
result.SnrSettleMinBlock = options.SnrSettleMinBlock;
result.DlevStepSizePvtTrack = options.DlevStepSizePvtTrack;
result.FfeAdaptEnableMask = logical(options.FfeAdaptEnableMask);
result.LevelCenter = levelCenter;
result.DlevInnerReference = dlevInnerReference;
result.DlevOuterReference = dlevOuterReference;
result.DlevInnerInit = options.DlevInnerInit;
result.DlevOuterInit = options.DlevOuterInit;
result.LoopKp = options.Kp;
result.LoopKi = options.Ki;
result.LoopMaxDeltaCode = options.MaxDeltaCode;
result.LoopFrequencyLimit = options.FrequencyLimit;
result.PdPolarity = options.Polarity;
result.DlevStepSize = options.StepSize;
result.DlevStepSizeSettle = options.StepSizeSettle;
result.PiNumBit = 7;
result.BaseUi = baseUi;
result.UiGuard = uiGuard;
result.NumBlocks = numBlocks;
result.StartPhaseList = startPhaseList;
result.PhaseCodeTrace = phaseCodeTrace;
result.UiSlipTrace = uiSlipTrace;
result.UnwrappedPhaseTrace = unwrappedPhaseTrace;
result.DriftSampleTrace = driftSampleTrace;
result.DriftExactTrace = driftExactTrace;
result.EyePhaseUnwrappedTrace = eyePhaseUnwrappedTrace;
result.PiTrackingErrorTrace = piTrackingErrorTrace;
result.TimingErrorTrace = timingErrorTrace;
result.DeltaCodeTrace = deltaCodeTrace;
result.LoopControlTrace = loopControlTrace;
result.LoopFrequencyStateTrace = loopFrequencyTrace;
result.LoopCodeResidueTrace = loopCodeResidueTrace;
result.LoopPendingCodeTrace = loopPendingCodeTrace;
result.EdgeCountTrace = edgeCountTrace;
result.SnrDbTrace = snrDbTrace;
result.DlevInnerTrace = dlevInnerTrace;
result.DlevOuterTrace = dlevOuterTrace;
result.DlevThresholdTrace = dlevThresholdTrace;
result.FfeCoeffTrace = ffeCoeffTrace;
result.SettleDoneFlag = settleDoneFlag;
result.SettleBlocks = settleBlocks;
result.LockWindowBlocks = piLockWindowBlocks;
result.LockMinEvents = piLockMinEvents;
result.LockBandHalfWidth = piLockBandHalfWidth;
result.CaptureBandHalfWidth = captureBandHalfWidth;
result.FreqLockFlag = freqLockFlag;
result.RotationLockFlag = rotationLockFlag;
result.FreqLockDiagnostics = [freqDiagList{:}];
result.RotationLockDiagnostics = [rotationDiagList{:}];
result.PiCenterDiagnostics = [piCenterDiagnostics{:}];
result.FirstCaptureBlock = firstCaptureBlock;
result.Stage2GateBlock = stage2GateBlock;
result.Stage1SettleBlock = stage1SettleBlock;
result.SlowestCapturePhaseIndex = slowestIndex;
result.SlowestCaptureStartPhase = slowestLockedStartPhase;
result.SlowestFirstCaptureBlock = slowestLockedCaptureBlock;
% Row rendered in the per-start diagnostic figures: the slowest locked capture,
% or (when nothing locked) the worst failing start for debugging.
result.PlotStartPhaseIndex = plotIndex;
result.PlotStartPhase = selectedStartPhase;
result.PlotIsLocked = plotIsLocked;
result.PhaseSettleStd = phaseSettleStd;
result.LockedPhaseCode = lockedPhaseCode;
result.LockedFlag = lockedFlag;
result.CommonLockPhase = commonLockPhase;
result.PhaseSpread = phaseSpread;
result.AllPhaseBandCode = allPhaseBand;
result.AllPhaseLock = allPhaseLock;
result.AllStartsConverged = all(lockedFlag);
result.RunOptions = options;
result.DlevInnerFinal = dlevInnerFinal;
result.DlevOuterFinal = dlevOuterFinal;
result.DlevInnerSpread = dlevInnerSpread;
result.DlevOuterSpread = dlevOuterSpread;
result.DlevInnerTruthError = dlevInnerTruthError;
result.DlevOuterTruthError = dlevOuterTruthError;
result.DlevConsistent = dlevConsistent;
result.FfeFinalCoefficients = ffeFinalCoefficients;
result.FfeCoeffMean = ffeCoeffMean;
result.FfeCoeffSpread = ffeCoeffSpread;
result.FfeConsistent = ffeConsistent;
result.DisplayEvalOffset = displayEvalOffset;
result.DisplayNormalizedCursor = displayNormalizedCursor;
result.HistogramPhaseIndex = histogramPhaseIndex;
result.HistogramSamples = histogramSamples;
result.ConvergenceFigurePath = convergenceFigurePath;
result.LockSummaryFigurePath = lockSummaryFigurePath;
result.DlevConvergenceFigurePath = dlevConvergenceFigurePath;
result.FfeConvergenceFigurePath = ffeConvergenceFigurePath;
result.FfeHistogramFigurePath = ffeHistogramFigurePath;
result.TotalPathResponseFigurePath = totalPathResponseFigurePath;
result.LoopFreqStateFigurePath = loopDitherFigurePath;
result.TrackingErrorFigurePath = trackingErrorFigurePath;
result.ResultMatPath = resultMatPath;
% Resolved second-stage gate criterion for this run, recorded so a saved
% result is self-describing about which gate produced its Stage2 block.
result.FfeGateCriterion = ffeGateCriterion;
% PI nonideality actually applied. The waveform address now comes from the PI
% phase table, so this field changes the simulated sampling instants.
result.PiNonideal = piNonideal;

if options.SaveOutputs
    % The former ppm_lock_summary.csv was removed: helpers/
    % write_ppm_lock_summary_txt.m emits ppm_lock_summary.txt, a strict
    % superset of those columns in a human-readable per-start-phase form,
    % recomputed from this result MAT.
    save(resultMatPath, 'result', '-v7.3');
end

fprintf(['cdr_three_loop_ppm @ %+g ppm completed: %d/%d start phases locked ' ...
    '(all-phase lock = %d).\n'], options.FreqOffsetPpm, sum(lockedFlag), ...
    numStartPhase, allPhaseLock);
end

function snrDb = blockDecisionSnrDb(decision, sliceError)
%BLOCKDECISIONSNRDB Decision-directed eye-quality FOM for one block.
%   Both inputs are already valid-sample-only: cdr_top masks the FFE output
%   (ffeOutput = blockOutput(blockValid)) before slicing, so decision and
%   sliceError carry only settled taps. The FOM is decision-level power over
%   slice-error power in dB.
%
%   This is decision-directed, NOT truth-referenced: when the eye is closed
%   and a sample is sliced to the wrong level, the error is measured against
%   that wrong level and can read optimistically. Any settle gate built on
%   this FOM must be validated against a known-closed-eye window rather than
%   assumed monotone.
decision = double(decision(:));
sliceError = double(sliceError(:));
if isempty(decision) || isempty(sliceError)
    snrDb = NaN;
    return;
end
errorPower = mean(sliceError .^ 2);
if errorPower <= 0
    snrDb = Inf;
    return;
end
snrDb = 10 * log10(mean(decision .^ 2) / errorPower);
end

function options = parseLoopOptions(varargin)
defaults = struct();
defaults.FreqOffsetPpm = 100;
defaults.Kp = 8.0;
defaults.Ki = 0.03;
defaults.MaxDeltaCode = 1;
defaults.FrequencyLimit = 4;
% Frequency-acquisition aid (runner-side schedule only; no src/CDR change).
% With a cold planB FFE the eye is closed while the ppm offset already drifts
% the sampling point, so from the far initial phases the loop latches the wrong
% S-curve slope and runs the integrator to the frequency clamp. Running the
% integral path off (proportional-only, a type-1 loop) during acquisition makes
% the loop follow the drift with a small static phase error while staying on the
% correct slope; once the eye is open (dLev settle) the integral gain is enabled
% and the integrator builds the correct steady frequency. The dLev-settle
% mu-downshift inside cdr_top is untouched; this only schedules Ki.
defaults.FreqAcqPonly = false;
defaults.Polarity = 1;
% MMPD transition qualification. true keeps only the symmetric -3<->+3 and
% -1<->+1 transitions (fewer, cleaner PD samples, lower ISI-induced bias);
% false uses every non-static transition (about 3x more PD samples per block,
% lower variance, but asymmetric transitions add their own bias). Under a cold
% FFE the symmetric filter also depends on the extreme symbols being decided
% correctly, which is exactly what a closed eye breaks.
defaults.TransitionFilter = true;
defaults.StepSize = 0.5;
defaults.StepSizeSettle = 0.1;
defaults.DlevSettleWindow = 16;
defaults.DlevSettleTol = 0.5;
% Two-stage mu downshift.
%   Stage 1 (capture -> settle) is gated on eye quality: the averaged
%   decision-directed SNR crossing SnrSettleThresholdDb. The legacy 'dlev'
%   gate fires on an outer-dLev displacement test that a slowly ramping dLev
%   satisfies while the eye is still closed; measured at -100 ppm it fired at
%   block 84 with 59% of the dLev trajectory still ahead, cut the FFE step 20x
%   and left the eye closed, so no start phase could acquire.
%   Stage 2 (settle -> PVT track) reuses the existing phase-band lock gate
%   (FfeGate*) and drops both loops again to tracking-only step sizes.
defaults.SettleGate = 'snr';
defaults.SnrSettleThresholdDb = 15;
defaults.SnrSettleAlpha = 1 / 128;
defaults.SnrSettleMinBlock = 200;
defaults.DlevStepSizePvtTrack = 0.02;
defaults.DlevPolarity = 1;
defaults.DlevOuterInit = 48;
defaults.DlevInnerInit = 16;
% Capture-mu for the CDR FFE. This is deliberately 4x smaller than the
% cdr_top library default (0.004) because the main tap is frozen
% (FfeAdaptEnableMask index 3 = 0), so the only way the loop can reshape the
% pulse is by growing the pre/post taps, which walks the effective cursor and
% therefore moves the MMPD zero. The walk is proportional to the capture step:
% measured locked-phase spread at 0 ppm over 8 start phases was 3 / 6 / 12 / 21
% codes for 0.001 / 0.002 / 0.004 / 0.008, with the same monotone trend at
% +100 ppm. 0.001 is the largest step that still keeps every ppm case inside
% the capture band.
defaults.FfeStepSize = 0.001;
defaults.FfeStepSizeSettle = 0.0002;
defaults.FfeAdaptEnableMask = logical([1 1 0 1 1 1]);
defaults.FfeInitMode = 'planB';
defaults.FfeBiasScale = 0;
defaults.FfeFreezeEnable = true;
defaults.FfeFreezeMinModeOccurrences = 500;
defaults.FfeFreezeMinEvents = 100;
defaults.FfeFreezeBandHalfWidth = 3;
defaults.FfeFreezeMode = 'pvt-track';
defaults.FfeStepSizePvtTrack = 0.0002;
% Gate criterion for the second-stage downshift. 'auto' picks 'center-touch'
% at exactly zero frequency offset and 'freq-state' otherwise, mirroring the
% way the offline pass/fail verdict already switches between the modal and the
% frequency-domain criteria. Force either name to override.
defaults.FfeGateCriterion = 'auto';
% PI phase-table nonideality: 'ab_constant' (cdr_pi's physical a+b=1 atan2
% model, 2.891 LSB pk-pk INL) or 'ideal' (exactly linear).
defaults.PiNonideal = 'ab_constant';
defaults.LockWindowBlocks = 2000;
defaults.FreqMeanHalfDiffTol = 0.03;
defaults.FreqStdTol = 0.08;
defaults.FreqRateTol = 0.12;
defaults.RotMinIntervals = 6;
defaults.RotCovTol = 0.15;
% Rotation-period match tolerance. A FRACTION of the expected period, not an
% absolute block count: an absolute tolerance lets a slew-saturated loop pass
% (at MaxDeltaCode=1 the PI advances exactly 1 code/block, so the rotation
% period is pinned at exactly SamplesPerSymbol blocks, which can sit within a
% loose absolute window of the expected period while the loop is not tracking
% at all). Set RotPeriodTol non-empty to override with an absolute block count.
defaults.RotPeriodTolFrac = 0.03;
defaults.RotPeriodTol = [];
% Slew-saturation guard: a loop whose per-block PI increment is pinned at
% MaxDeltaCode, or which carries a persistent clipped-code backlog in
% PendingCode, cannot be tracking the offset and is disqualified from lock.
defaults.SlewSatDeltaFrac = 0.98;
defaults.SlewSatPendingTol = 0.5;
defaults.SaveOutputs = true;
defaults.ResultDir = '';
defaults.StartPhaseList = [];
defaults.StartPhaseStep = 16;
defaults.CosimDir = 'channel_ctle_cosim_prbs22';
defaults.NumBlock = 15000;
defaults.AnalysisNumUi = [];
options = defaults;
providedNames = {};
if isscalar(varargin) && isstruct(varargin{1})
    provided = varargin{1};
    providedNames = fieldnames(provided);
    for index = 1:numel(providedNames)
        options.(providedNames{index}) = provided.(providedNames{index});
    end
elseif ~isempty(varargin)
    assert(mod(numel(varargin), 2) == 0, ...
        'Loop options must be name/value pairs.');
    providedNames = varargin(1:2:end);
    for index = 1:2:numel(varargin)
        options.(varargin{index}) = varargin{index + 1};
    end
end
gaveAnalysisNumUi = any(strcmp('AnalysisNumUi', providedNames)) && ...
    ~isempty(options.AnalysisNumUi);
expectedAnalysisNumUi = analysisUiFor(options.NumBlock, ...
    options.FreqOffsetPpm);
if ~gaveAnalysisNumUi
    options.AnalysisNumUi = expectedAnalysisNumUi;
else
    assert(options.AnalysisNumUi == expectedAnalysisNumUi, ...
        'AnalysisNumUi is inconsistent with NumBlock and FreqOffsetPpm.');
end
end

function analysisNumUi = analysisUiFor(numBlock, freqOffsetPpm)
adcBlockUi = 64;
driftBudgetUi = ceil(abs(freqOffsetPpm) * 1e-6 * numBlock * adcBlockUi);
% Round the two-sided drift margin up to a whole number of 64-UI ADC blocks so
% the fixed analysis segment always contains complete blocks.
marginUi = ceil(2 * driftBudgetUi / adcBlockUi) * adcBlockUi;
analysisNumUi = numBlock * adcBlockUi + 512 + marginUi;
end

function validateOptions(options)
validateattributes(options.FreqOffsetPpm, {'numeric'}, ...
    {'scalar', 'real', 'finite'});
validateattributes(options.NumBlock, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', 'positive'});
validateattributes(options.AnalysisNumUi, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', 'positive'});
validateattributes(options.StartPhaseStep, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', '>=', 1, '<=', 128});
if ~isempty(options.StartPhaseList)
    validateattributes(options.StartPhaseList, {'numeric'}, ...
        {'vector', 'real', 'finite', 'integer', '>=', 0, '<', 128});
end
validateattributes(options.LockWindowBlocks, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', 'positive'});
validateattributes(options.MaxDeltaCode, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'integer', 'positive'});
validateattributes(options.RotPeriodTolFrac, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'nonnegative'});
if ~isempty(options.RotPeriodTol)
    validateattributes(options.RotPeriodTol, {'numeric'}, ...
        {'scalar', 'real', 'nonnegative'});
end
validateattributes(options.SlewSatDeltaFrac, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive', '<=', 1});
validateattributes(options.SlewSatPendingTol, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'nonnegative'});
validateattributes(options.SaveOutputs, {'numeric', 'logical'}, ...
    {'scalar', 'real', 'finite'});
assert(any(double(options.SaveOutputs) == [0 1]), ...
    'SaveOutputs must be logical or numeric 0/1.');
assert(any(strcmpi(char(options.FfeFreezeMode), {'freeze', 'pvt-track'})), ...
    'FfeFreezeMode must be freeze or pvt-track.');
end

function value = ternaryChar(condition, trueText, falseText)
if condition
    value = trueText;
else
    value = falseText;
end
end

function flag = getCachePeriodFlag(cacheFile)
names = who(cacheFile);
if ismember('isCompletePrbsPeriod', names)
    flag = cacheFile.isCompletePrbsPeriod;
else
    flag = cacheFile.isCompletePrbs20Period;
end
end

function outputValid = processOnePhase(segment, phase, samplePerSymbol, ...
    adcLaneCount, adcSarPerTah, adcResolutionBits, adcFullRange, ...
    adcZeroCode, laneToTimeOrder, nominalBlockLength, ...
    cdrFfeCoefficients, cdrFfePreTapCount, blockUi)
numUi = floor((numel(segment) - phase - 1) / samplePerSymbol) + 1;
numBlocks = floor(numUi / blockUi);
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
ffeModel = cdr_ffe(cdrFfeCoefficients, cdrFfePreTapCount);
postTapCount = ffeModel.PostTapCount;
codeStream = zeros(1, numBlocks * blockUi);
for blockIndex = 1:numBlocks
    firstUi = (blockIndex - 1) * blockUi;
    blockStart = firstUi * samplePerSymbol + phase + 1;
    blockStop = blockStart + nominalBlockLength - 1;
    physicalCode = adcModel.convertOneBlockFast( ...
        segment(blockStart:blockStop), 1);
    centeredCode = double(physicalCode(laneToTimeOrder)) - adcZeroCode;
    codeStream((blockIndex - 1) * blockUi + (1:blockUi)) = centeredCode;
end
inputWindow = [zeros(1, postTapCount), codeStream, ...
    zeros(1, cdrFfePreTapCount)];
outputBlock = ffeModel.processBlock(inputWindow);
valid = true(1, numel(outputBlock));
valid(1:postTapCount) = false;
valid(end - cdrFfePreTapCount + 1:end) = false;
outputValid = outputBlock(valid);
end

function [laneToTimeOrder, nominalBlockLength] = adcLaneOrdering( ...
    adcLaneCount, adcSarPerTah, samplePerSymbol)
laneNumber = 1:adcLaneCount;
numTah = adcLaneCount / adcSarPerTah;
lanePhaseIndex = floor((laneNumber - 1) / adcSarPerTah) + 1;
laneSarIndex = mod(laneNumber - 1, adcSarPerTah) + 1;
laneTimeOrderIndex = (laneSarIndex - 1) * numTah + lanePhaseIndex;
[~, laneToTimeOrder] = sort(laneTimeOrderIndex);
nominalBlockLength = (adcLaneCount - 1) * samplePerSymbol + 1;
end

function sample = samplePulseAtPhase(pulse, samplePerSymbol, phase, offset)
[~, pulsePeakIndex] = max(abs(pulse));
mainUi = round((pulsePeakIndex - 1 - phase) / samplePerSymbol);
mainIndex = mainUi * samplePerSymbol + phase + 1;
sampleIndex = mainIndex + offset * samplePerSymbol;
assert(sampleIndex(1) >= 1 && sampleIndex(end) <= numel(pulse), ...
    'Requested symbol-pulse cursor window exceeds available data.');
sample = reshape(pulse(sampleIndex), 1, []);
end

function regressor = buildPathRegressor(symbolPulse, samplePerSymbol, ...
    phase, evalOffset, tapOffset, adcLaneCount, adcSarPerTah, ...
    adcResolutionBits, adcFullRange, laneToTimeOrder, nominalBlockLength, ...
    adcZeroCode)
channelOffset = (evalOffset(1) - tapOffset(end)): ...
    (evalOffset(end) - tapOffset(1));
analog = samplePulseAtPhase(symbolPulse, samplePerSymbol, phase, channelOffset);
codeQuantized = quantizeSamplesWithTiAdc(analog, adcLaneCount, ...
    adcSarPerTah, adcResolutionBits, adcFullRange, samplePerSymbol, ...
    laneToTimeOrder, nominalBlockLength);
codeCentered = codeQuantized - adcZeroCode;
regressor = zeros(numel(evalOffset), numel(tapOffset));
for row = 1:numel(evalOffset)
    for column = 1:numel(tapOffset)
        requiredOffset = evalOffset(row) - tapOffset(column);
        channelIndex = find(channelOffset == requiredOffset, 1);
        regressor(row, column) = codeCentered(channelIndex);
    end
end
end

function code = quantizeSamplesWithTiAdc(sample, adcLaneCount, ...
    adcSarPerTah, adcResolutionBits, adcFullRange, samplePerSymbol, ...
    laneToTimeOrder, nominalBlockLength)
assert(numel(sample) <= adcLaneCount, ...
    'Cursor sample count exceeds one TI ADC block.');
adcModel = ti_adc_top(adcLaneCount, -adcFullRange, adcFullRange, ...
    adcResolutionBits, adcSarPerTah, samplePerSymbol);
adcModel.setInputMargin(0);
waveform = zeros(1, nominalBlockLength);
sampleLocation = 1 + (0:adcLaneCount - 1) * samplePerSymbol;
waveform(sampleLocation(1:numel(sample))) = sample;
physicalCode = adcModel.convertOneBlockFast(waveform, 1);
timeOrderedCode = double(physicalCode(laneToTimeOrder));
code = timeOrderedCode(1:numel(sample));
end

function [coefficients, design] = optimizeCdrFfe( ...
    channelCursor, channelOffset, tapOffset, evalOffset)
mainTapIndex = find(tapOffset == 0, 1);
freeTapMask = tapOffset ~= 0;
regressor = zeros(numel(evalOffset), numel(tapOffset));
for row = 1:numel(evalOffset)
    for column = 1:numel(tapOffset)
        requiredOffset = evalOffset(row) - tapOffset(column);
        channelIndex = find(channelOffset == requiredOffset, 1);
        regressor(row, column) = channelCursor(channelIndex);
    end
end
freeRegressor = regressor(:, freeTapMask);
fixedMainResponse = regressor(:, mainTapIndex);
pre1Row = find(evalOffset == -1, 1);
mainRow = find(evalOffset == 0, 1);
post1Row = find(evalOffset == 1, 1);
constraintMatrix = [ ...
    freeRegressor(pre1Row, :) - 0.05 * freeRegressor(mainRow, :); ...
    freeRegressor(post1Row, :) - 0.05 * freeRegressor(mainRow, :)];
constraintTarget = -[ ...
    fixedMainResponse(pre1Row) - 0.05 * fixedMainResponse(mainRow); ...
    fixedMainResponse(post1Row) - 0.05 * fixedMainResponse(mainRow)];
otherCursorMask = ~ismember(evalOffset, [-1 0 1]);
objectiveMatrix = freeRegressor(otherCursorMask, :);
objectiveTarget = fixedMainResponse(otherCursorMask);
normalMatrix = objectiveMatrix.' * objectiveMatrix;
regularizationScale = max(trace(normalMatrix) / size(normalMatrix, 1), eps);
regularization = 1e-8 * regularizationScale;
kktMatrix = [normalMatrix + regularization * eye(size(normalMatrix)), ...
    constraintMatrix.'; constraintMatrix, zeros(size(constraintMatrix, 1))];
kktTarget = [-objectiveMatrix.' * objectiveTarget; constraintTarget];
kktSolution = kktMatrix \ kktTarget;
coefficients = zeros(1, numel(tapOffset));
coefficients(mainTapIndex) = 1;
coefficients(freeTapMask) = kktSolution(1:nnz(freeTapMask));
outputCursor = reshape(regressor * coefficients(:), 1, []);
normalizedCursor = outputCursor / outputCursor(mainRow);
design = struct('TapOffset', tapOffset, 'EvalOffset', evalOffset, ...
    'Regularization', regularization, 'Regressor', regressor, ...
    'OutputCursor', outputCursor, 'NormalizedCursor', normalizedCursor, ...
    'OtherCursorRms', sqrt(mean(normalizedCursor(otherCursorMask) .^ 2)), ...
    'OtherCursorMax', max(abs(normalizedCursor(otherCursorMask))));
end

function center = estimatePam4Centers(sample)
center = prctile(sample, [12.5 37.5 62.5 87.5]);
for iteration = 1:50
    [~, cluster] = min(abs(sample(:) - center), [], 2);
    updated = center;
    for level = 1:4
        levelSample = sample(cluster == level);
        if ~isempty(levelSample)
            updated(level) = mean(levelSample);
        end
    end
    if max(abs(updated - center)) < 1e-12
        break;
    end
    center = updated;
end
center = sort(center);
end

function [refHandle, convHandle] = addDlevHistogramReferenceLines(ax, ...
    levelCenter, dlevInnerFinalValue, dlevOuterFinalValue)
refHandle = xline(ax, levelCenter(1), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
xline(ax, levelCenter(2), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
xline(ax, levelCenter(3), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
xline(ax, levelCenter(4), '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0);
convHandle = xline(ax, -dlevOuterFinalValue, 'r--', 'LineWidth', 1.0);
xline(ax, -dlevInnerFinalValue, 'r--', 'LineWidth', 1.0);
xline(ax, dlevInnerFinalValue, 'r--', 'LineWidth', 1.0);
xline(ax, dlevOuterFinalValue, 'r--', 'LineWidth', 1.0);
end

function saveFigureResilient(figureHandle, filePath)
set(figureHandle, 'Visible', 'on');
maxAttempts = 5;
for attempt = 1:maxAttempts
    try
        savefig(figureHandle, filePath);
        return;
    catch saveError
        if attempt == maxAttempts
            warning('cdr_three_loop_ppm:FigureSaveFailed', ...
                'Could not save "%s": %s', filePath, saveError.message);
            return;
        end
        pause(0.5);
    end
end
end

function drawStageMarkers(stage1Block, stage2Block, snrThresholdDb, ...
        gateCriterion, labeled)
%DRAWSTAGEMARKERS Mark the two mu-downshift milestones on a block-axis plot.
%
% The convergence traces change slope at the two step-size downshifts, so
% marking them makes those kinks attributable instead of mysterious:
%   stage 1: capture -> settle, gated by the SNR-EWMA threshold
%            (dLev 0.5 -> 0.1, FFE 1e-3 -> 2e-4)
%   stage 2: settle -> PVT-track, gated by FfeGateCriterion
%            (dLev 0.1 -> 0.02; FFE unchanged at the default tuning)
%
% The stage-2 label names the armed gate rather than calling the event a
% "lock": only the 'freq-state' gate is a component of the lock criterion.
% The 'center-touch' gate is an independent code-domain test, so labelling its
% trigger as a lock would misstate what the line marks.
%
% Both inputs are NaN-safe: a milestone that never fired is simply not drawn,
% which is the normal case for stage 2 under the legacy center-touch gate at
% a nonzero frequency offset. Colors are deliberately distinct from the red
% acquisition marker already present on these axes.
if isfinite(stage1Block)
    if labeled
        xline(stage1Block, '--', ...
            sprintf('stage-1 downshift (SNR>%gdB) block %g', ...
            snrThresholdDb, stage1Block), ...
            'Color', [0.00 0.55 0.25], 'LineWidth', 1.2, ...
            'LabelVerticalAlignment', 'bottom');
    else
        xline(stage1Block, '--', 'Color', [0.00 0.55 0.25], ...
            'LineWidth', 1.0);
    end
end
if isfinite(stage2Block)
    if labeled
        xline(stage2Block, '--', ...
            sprintf('stage-2 downshift (gate: %s) block %g', ...
            char(gateCriterion), stage2Block), ...
            'Color', [0.50 0.15 0.70], 'LineWidth', 1.2, ...
            'LabelVerticalAlignment', 'middle');
    else
        xline(stage2Block, '--', 'Color', [0.50 0.15 0.70], ...
            'LineWidth', 1.0);
    end
end
end
