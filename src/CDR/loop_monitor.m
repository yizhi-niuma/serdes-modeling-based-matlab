classdef loop_monitor < handle
    %LOOP_MONITOR Causal block-rate policy detectors for the CDR adaptation loops.
    %
    % The monitor observes one block at a time and reports one-shot policy
    % events. It only decides; it never holds loop objects and never applies
    % a step size, a coefficient or a gate. The caller reads the returned
    % trigger and applies the action, so the data path stays in cdr_top.
    %
    % Three independent causal detectors are provided.
    %
    % 1) FFE write gate (formerly ffe_freeze_monitor). Three states: before
    %    StartBlock samples are ignored; SEARCH counts each observed unwrapped
    %    PI code once and qualifies the lowest-valued mode when its count
    %    reaches MinModeOccurrences; CANDIDATE fixes that mode as
    %    CenterUnwrapped and counts center touches and strict side-to-side
    %    crossings inside the inclusive center band. An outlier abandons the
    %    candidate and clears all SEARCH history, and the outlier itself is not
    %    the first sample of the new search. Reaching MinEvents enters FROZEN
    %    permanently. updateFfeGate returns true only on that transition.
    %    No sample trace is retained, only sparse SEARCH counts.
    %
    % 2) dLev settle detector. A one-shot comparison of the current outer dLev
    %    against the value recorded DlevSettleWindow blocks earlier. The
    %    history is a ring buffer of DlevSettleWindow+1 entries, so memory is
    %    bounded regardless of the simulation length. Callers must record the
    %    post-update outer level once per block with recordDlevOuter.
    %
    % 3) Eye-quality (SNR) settle detector. A one-shot trigger on an
    %    exponentially weighted average of a per-block decision-directed SNR
    %    in dB. Memory is one scalar, so it is bounded by construction. It
    %    exists because the dLev settle detector above is a displacement test
    %    over a fixed window, i.e. an implicit drift-rate threshold of
    %    DlevSettleTol/DlevSettleWindow: a dLev level that is still ramping
    %    slowly satisfies it and reports settle while the eye is still closed.
    %    The SNR detector instead observes the quantity that actually matters
    %    for a mu downshift, namely whether the eye is open. Per-block SNR is
    %    far too noisy to threshold directly (a drifting unlocked loop sweeps
    %    through the eye centre and produces good single-block readings), so
    %    the average is mandatory rather than cosmetic. Enable it explicitly
    %    with enableSnrSettle; the constructor arity is unchanged.
    %
    % 4) Loop-frequency-state lock gate. A one-shot ONLINE form of the
    %    detectFrequencyStateLock criterion defined below. It keeps a ring
    %    buffer of the last windowBlocks loop frequency-state samples and,
    %    once that buffer is full, hands the ordered window to that very same
    %    static detector. The online verdict is therefore identical by
    %    construction to the offline one evaluated over the same trailing
    %    window: there is no second copy of the criterion to drift out of
    %    sync. Memory is one window regardless of run length, and the cost is
    %    O(windowBlocks) per block only until the gate latches.
    %
    %    It exists because detector 1 above is a CODE-DOMAIN center-touch
    %    test. Under a frequency offset the PI code ramps continuously and
    %    never dwells on a single code, so detector 1 can never reach its
    %    mode count and a gate built on it never fires. The loop frequency
    %    state is instead exactly the quantity that goes constant once the
    %    loop tracks the offset, so it stays meaningful at any ppm including
    %    zero. Enable it explicitly with enableFreqStateGate; the documented
    %    constructor arity is unchanged.
    %
    % The detector previously named ffe_freeze_monitor is unchanged in
    % behaviour; only the class name and error identifiers moved.

    properties (SetAccess = private)
        MinModeOccurrences
        MinEvents
        BandHalfWidth
        StartBlock
        Frozen = false
        FreezeBlock = NaN
        CenterUnwrapped = NaN
        CandidateStartBlock = NaN
        ModeOccurrences = 0
        EventCount = 0
        ResetCount = 0
        LastBlock = NaN
        DlevSettleEnabled = false
        DlevSettleWindow = NaN
        DlevSettleTol = NaN
        SettleDone = false
        SettleBlock = NaN
        SnrSettleEnabled = false
        SnrSettleThresholdDb = NaN
        SnrSettleAlpha = NaN
        SnrSettleMinBlock = NaN
        SnrEwmaDb = NaN
        SnrSettleDone = false
        SnrSettleBlock = NaN
        FreqGateEnabled = false
        FreqGateWindow = NaN
        FreqGateExpectedRate = NaN
        FreqGateMeanHalfDiffTol = NaN
        FreqGateStdTol = NaN
        FreqGateRateTol = NaN
        FreqGateMinBlock = NaN
        FreqGateDone = false
        FreqGateBlock = NaN
        FreqGateSampleCount = 0
        FreqGateSkippedCount = 0
    end

    properties (Access = private)
        SearchCodes = zeros(1, 0)
        SearchCounts = zeros(1, 0)
        HavePrevious = false
        PreviousCode = NaN
        DlevRingValue = zeros(1, 0)
        DlevRingBlock = zeros(1, 0)
        FreqRingValue = zeros(1, 0)
    end

    methods
        function obj = loop_monitor(minModeOccurrences, minEvents, ...
                bandHalfWidth, startBlock, dlevSettleWindow, dlevSettleTol)
            %LOOP_MONITOR Construct with explicit thresholds.
            %
            %   loop_monitor(minModeOccurrences, minEvents, bandHalfWidth, ...
            %       startBlock)
            %       enables the FFE write gate only.
            %
            %   loop_monitor(..., dlevSettleWindow, dlevSettleTol)
            %       additionally enables the dLev settle detector.
            if nargin ~= 4 && nargin ~= 6
                error('loop_monitor:InvalidConstructor', ...
                    ['Expected minModeOccurrences, minEvents, ', ...
                    'bandHalfWidth, and startBlock, optionally followed by ', ...
                    'dlevSettleWindow and dlevSettleTol.']);
            end
            obj.validateInteger(minModeOccurrences, 1, ...
                'InvalidMinModeOccurrences', 'minModeOccurrences');
            obj.validateInteger(minEvents, 1, ...
                'InvalidMinEvents', 'minEvents');
            obj.validateInteger(bandHalfWidth, 0, ...
                'InvalidBandHalfWidth', 'bandHalfWidth');
            obj.validateInteger(startBlock, 1, ...
                'InvalidStartBlock', 'startBlock');
            obj.MinModeOccurrences = double(minModeOccurrences);
            obj.MinEvents = double(minEvents);
            obj.BandHalfWidth = double(bandHalfWidth);
            obj.StartBlock = double(startBlock);

            if nargin == 6
                obj.validateInteger(dlevSettleWindow, 1, ...
                    'InvalidDlevSettleWindow', 'dlevSettleWindow');
                obj.validateTolerance(dlevSettleTol);
                obj.DlevSettleEnabled = true;
                obj.DlevSettleWindow = double(dlevSettleWindow);
                obj.DlevSettleTol = double(dlevSettleTol);
            end

            obj.resetState();
        end

        function resetState(obj)
            %RESETSTATE Clear all dynamic state while preserving configuration.
            obj.Frozen = false;
            obj.FreezeBlock = NaN;
            obj.CenterUnwrapped = NaN;
            obj.CandidateStartBlock = NaN;
            obj.ModeOccurrences = 0;
            obj.EventCount = 0;
            obj.ResetCount = 0;
            obj.LastBlock = NaN;
            obj.SearchCodes = zeros(1, 0);
            obj.SearchCounts = zeros(1, 0);
            obj.HavePrevious = false;
            obj.PreviousCode = NaN;
            obj.SettleDone = false;
            obj.SettleBlock = NaN;
            if obj.DlevSettleEnabled
                ringLength = obj.DlevSettleWindow + 1;
                obj.DlevRingValue = nan(1, ringLength);
                obj.DlevRingBlock = nan(1, ringLength);
            else
                obj.DlevRingValue = zeros(1, 0);
                obj.DlevRingBlock = zeros(1, 0);
            end
            obj.FreqGateDone = false;
            obj.FreqGateBlock = NaN;
            obj.FreqGateSampleCount = 0;
            obj.FreqGateSkippedCount = 0;
            if obj.FreqGateEnabled
                obj.FreqRingValue = nan(1, obj.FreqGateWindow);
            else
                obj.FreqRingValue = zeros(1, 0);
            end
        end

        function triggered = update(obj, unwrappedCode, blockIndex)
            %UPDATE Observe one block for the FFE write gate.
            %
            % Retained name so existing runners keep working; identical to
            % updateFfeGate.
            triggered = obj.updateFfeGate(unwrappedCode, blockIndex);
        end

        function triggered = updateFfeGate(obj, unwrappedCode, blockIndex)
            %UPDATEFFEGATE Observe one block and report only the gate transition.
            obj.validateInteger(unwrappedCode, -Inf, ...
                'InvalidCode', 'unwrappedCode');
            obj.validateInteger(blockIndex, 1, ...
                'InvalidBlock', 'blockIndex');
            blockIndex = double(blockIndex);
            if ~isnan(obj.LastBlock) && blockIndex <= obj.LastBlock
                error('loop_monitor:NonMonotonicBlock', ...
                    'blockIndex must be strictly greater than LastBlock.');
            end

            unwrappedCode = double(unwrappedCode);
            obj.LastBlock = blockIndex;
            triggered = false;

            % Frozen observations and pre-start observations only advance
            % LastBlock; neither can alter detector metadata.
            if obj.Frozen || blockIndex < obj.StartBlock
                return;
            end

            if isnan(obj.CenterUnwrapped)
                obj.observeSearch(unwrappedCode, blockIndex);
                return;
            end

            center = obj.CenterUnwrapped;
            if abs(unwrappedCode - center) > obj.BandHalfWidth
                obj.ResetCount = obj.ResetCount + 1;
                obj.clearCandidateAndSearch();
                return;
            end

            if unwrappedCode == center
                obj.ModeOccurrences = obj.ModeOccurrences + 1;
            end
            if obj.HavePrevious
                isCenterTouch = obj.PreviousCode ~= center && ...
                    unwrappedCode == center;
                isStrictCross = (obj.PreviousCode < center && ...
                    unwrappedCode > center) || ...
                    (obj.PreviousCode > center && unwrappedCode < center);
                if isCenterTouch || isStrictCross
                    obj.EventCount = obj.EventCount + 1;
                end
            end
            obj.PreviousCode = unwrappedCode;
            obj.HavePrevious = true;

            if obj.EventCount >= obj.MinEvents
                obj.Frozen = true;
                obj.FreezeBlock = blockIndex;
                triggered = true;
            end
        end

        function triggered = updateDlevSettle(obj, blockIndex, dlevOuter)
            %UPDATEDLEVSETTLE Report the one-shot dLev settle transition.
            %
            % dlevOuter is the outer level observed before this block's dLev
            % update, matching the reference block order. The comparison uses
            % the value recorded DlevSettleWindow blocks earlier.
            obj.requireDlevSettleEnabled('updateDlevSettle');
            obj.validateInteger(blockIndex, 1, 'InvalidBlock', 'blockIndex');
            obj.validateLevel(dlevOuter, 'dlevOuter');
            blockIndex = double(blockIndex);

            triggered = false;
            if obj.SettleDone || blockIndex <= obj.DlevSettleWindow
                return;
            end

            targetBlock = blockIndex - obj.DlevSettleWindow;
            slot = obj.ringSlot(targetBlock);
            if obj.DlevRingBlock(slot) ~= targetBlock
                error('loop_monitor:MissingDlevHistory', ...
                    ['No recorded outer dLev for block %d; call ', ...
                    'recordDlevOuter once per block.'], targetBlock);
            end

            if abs(double(dlevOuter) - obj.DlevRingValue(slot)) <= obj.DlevSettleTol
                obj.SettleDone = true;
                obj.SettleBlock = blockIndex;
                triggered = true;
            end
        end

        function recordDlevOuter(obj, blockIndex, dlevOuter)
            %RECORDDLEVOUTER Store this block's post-update outer dLev level.
            obj.requireDlevSettleEnabled('recordDlevOuter');
            obj.validateInteger(blockIndex, 1, 'InvalidBlock', 'blockIndex');
            obj.validateLevel(dlevOuter, 'dlevOuter');
            blockIndex = double(blockIndex);
            slot = obj.ringSlot(blockIndex);
            obj.DlevRingValue(slot) = double(dlevOuter);
            obj.DlevRingBlock(slot) = blockIndex;
        end

        function enableSnrSettle(obj, thresholdDb, alpha, minBlock)
            %ENABLESNRSETTLE Turn on the eye-quality settle detector.
            %
            %   thresholdDb is the averaged decision-directed SNR in dB at or
            %   above which the eye counts as open. alpha is the EWMA weight
            %   in (0, 1]; a smaller alpha means heavier smoothing. minBlock
            %   suppresses the trigger while the average is still warming up.
            %
            %   This is a separate configuration call rather than extra
            %   constructor arguments so the documented 4/6 constructor arity
            %   stays valid for every existing caller.
            if nargin ~= 4
                error('loop_monitor:InvalidSnrSettleConfig', ...
                    'Expected thresholdDb, alpha, and minBlock.');
            end
            isValidThreshold = isnumeric(thresholdDb) && ...
                isreal(thresholdDb) && isscalar(thresholdDb) && ...
                isfinite(thresholdDb);
            if ~isValidThreshold
                error('loop_monitor:InvalidSnrSettleThreshold', ...
                    'thresholdDb must be a finite real scalar.');
            end
            isValidAlpha = isnumeric(alpha) && isreal(alpha) && ...
                isscalar(alpha) && isfinite(alpha) && alpha > 0 && alpha <= 1;
            if ~isValidAlpha
                error('loop_monitor:InvalidSnrSettleAlpha', ...
                    'alpha must be a real scalar in (0, 1].');
            end
            obj.validateInteger(minBlock, 1, ...
                'InvalidSnrSettleMinBlock', 'minBlock');

            obj.SnrSettleEnabled = true;
            obj.SnrSettleThresholdDb = double(thresholdDb);
            obj.SnrSettleAlpha = double(alpha);
            obj.SnrSettleMinBlock = double(minBlock);
            obj.SnrEwmaDb = NaN;
            obj.SnrSettleDone = false;
            obj.SnrSettleBlock = NaN;
        end

        function triggered = updateSnrSettle(obj, blockIndex, snrDb)
            %UPDATESNRSETTLE Report the one-shot eye-quality settle transition.
            %
            % snrDb is this block's decision-directed SNR in dB. Blocks that
            % carry no usable eye information (no valid samples, or an exactly
            % zero error power, i.e. a non-finite reading) are skipped instead
            % of being folded in, so they can neither poison nor inflate the
            % average.
            obj.requireSnrSettleEnabled('updateSnrSettle');
            obj.validateInteger(blockIndex, 1, 'InvalidBlock', 'blockIndex');
            isValidSnr = isnumeric(snrDb) && isreal(snrDb) && isscalar(snrDb);
            if ~isValidSnr
                error('loop_monitor:InvalidSnr', ...
                    'snrDb must be a real scalar.');
            end

            triggered = false;
            if obj.SnrSettleDone
                return;
            end
            if ~isfinite(snrDb)
                return;
            end

            if isnan(obj.SnrEwmaDb)
                % Seed with the first usable reading; ramping up from zero
                % would otherwise delay the trigger by ~1/alpha blocks.
                obj.SnrEwmaDb = double(snrDb);
            else
                weight = obj.SnrSettleAlpha;
                obj.SnrEwmaDb = (1 - weight) * obj.SnrEwmaDb + ...
                    weight * double(snrDb);
            end

            if blockIndex < obj.SnrSettleMinBlock
                return;
            end
            if obj.SnrEwmaDb >= obj.SnrSettleThresholdDb
                obj.SnrSettleDone = true;
                obj.SnrSettleBlock = blockIndex;
                triggered = true;
            end
        end

        function enableFreqStateGate(obj, windowBlocks, expectedRate, ...
                meanHalfDiffTol, stdTol, rateTol, minBlock)
            %ENABLEFREQSTATEGATE Turn on the online frequency-state lock gate.
            %
            %   windowBlocks, expectedRate, meanHalfDiffTol, stdTol and
            %   rateTol carry exactly the meaning documented on the static
            %   detectFrequencyStateLock, because the online gate forwards
            %   them to that function unchanged. expectedRate may be NaN and
            %   rateTol may be Inf to test flatness only.
            %
            %   minBlock suppresses the trigger while the loop is still in its
            %   capture transient, in the same spirit as the SNR settle
            %   detector's own minBlock. The gate additionally cannot fire
            %   before windowBlocks samples have been observed, since a short
            %   window is rejected by the criterion itself.
            %
            %   This is a separate configuration call rather than extra
            %   constructor arguments so the documented 4/6 constructor arity
            %   stays valid for every existing caller.
            if nargin ~= 7
                error('loop_monitor:InvalidFreqGateConfig', ...
                    ['Expected windowBlocks, expectedRate, ', ...
                    'meanHalfDiffTol, stdTol, rateTol, and minBlock.']);
            end
            obj.validateInteger(windowBlocks, 2, ...
                'InvalidFreqGateWindow', 'windowBlocks');
            loop_monitor.validateFiniteOrNaNScalar(expectedRate, ...
                'expectedRate');
            loop_monitor.validateNonnegativeScalar(meanHalfDiffTol, ...
                'meanHalfDiffTol');
            loop_monitor.validateNonnegativeScalar(stdTol, 'stdTol');
            loop_monitor.validateNonnegativeScalarOrInf(rateTol, 'rateTol');
            obj.validateInteger(minBlock, 1, ...
                'InvalidFreqGateMinBlock', 'minBlock');

            obj.FreqGateEnabled = true;
            obj.FreqGateWindow = double(windowBlocks);
            obj.FreqGateExpectedRate = double(expectedRate);
            obj.FreqGateMeanHalfDiffTol = double(meanHalfDiffTol);
            obj.FreqGateStdTol = double(stdTol);
            obj.FreqGateRateTol = double(rateTol);
            obj.FreqGateMinBlock = double(minBlock);
            obj.FreqGateDone = false;
            obj.FreqGateBlock = NaN;
            obj.FreqGateSampleCount = 0;
            obj.FreqGateSkippedCount = 0;
            obj.FreqRingValue = nan(1, double(windowBlocks));
        end

        function [triggered, diag] = updateFreqStateGate(obj, blockIndex, ...
                freqState)
            %UPDATEFREQSTATEGATE Report the one-shot frequency-lock transition.
            %
            % freqState is this block's loop-filter integrator frequency state
            % in code/block, taken AFTER the loop filter update for the block,
            % so the observed sequence matches the recorded frequency-state
            % trace sample for sample.
            %
            % Non-finite samples are skipped rather than stored, because the
            % criterion rejects a non-finite window outright; such a sample
            % would make the offline detector error rather than return false.
            % Skips are counted in FreqGateSkippedCount so a run that relied
            % on them is not silently indistinguishable from a clean one.
            obj.requireFreqGateEnabled('updateFreqStateGate');
            obj.validateInteger(blockIndex, 1, 'InvalidBlock', 'blockIndex');
            isValidState = isnumeric(freqState) && isreal(freqState) && ...
                isscalar(freqState);
            if ~isValidState
                error('loop_monitor:InvalidFreqState', ...
                    'freqState must be a real scalar.');
            end

            triggered = false;
            diag = struct('WindowLength', 0, 'MeanValue', NaN, ...
                'MeanHalfDiff', NaN, 'TailStd', NaN, ...
                'ExpectedRate', obj.FreqGateExpectedRate, ...
                'RateError', NaN, 'FlatnessOk', false, 'RateOk', false);
            if obj.FreqGateDone
                return;
            end
            if ~isfinite(freqState)
                obj.FreqGateSkippedCount = obj.FreqGateSkippedCount + 1;
                return;
            end

            window = obj.FreqGateWindow;
            obj.FreqGateSampleCount = obj.FreqGateSampleCount + 1;
            slot = mod(obj.FreqGateSampleCount - 1, window) + 1;
            obj.FreqRingValue(slot) = double(freqState);

            if obj.FreqGateSampleCount < window
                return;
            end
            if blockIndex < obj.FreqGateMinBlock
                return;
            end

            % Oldest-to-newest view of the ring, i.e. the same trailing window
            % the offline criterion would take from the full trace.
            ordered = [obj.FreqRingValue(slot + 1:end), ...
                obj.FreqRingValue(1:slot)];
            [locked, diag] = loop_monitor.detectFrequencyStateLock( ...
                ordered, window, obj.FreqGateExpectedRate, ...
                obj.FreqGateMeanHalfDiffTol, obj.FreqGateStdTol, ...
                obj.FreqGateRateTol);
            if locked
                obj.FreqGateDone = true;
                obj.FreqGateBlock = blockIndex;
                triggered = true;
            end
        end

        function state = getState(obj)
            %GETSTATE Return a copy of configuration and bounded diagnostics.
            state = struct();
            state.Frozen = obj.Frozen;
            state.FreezeBlock = obj.FreezeBlock;
            state.CenterUnwrapped = obj.CenterUnwrapped;
            state.CandidateStartBlock = obj.CandidateStartBlock;
            state.ModeOccurrences = obj.ModeOccurrences;
            state.EventCount = obj.EventCount;
            state.ResetCount = obj.ResetCount;
            state.LastBlock = obj.LastBlock;
            state.MinModeOccurrences = obj.MinModeOccurrences;
            state.MinEvents = obj.MinEvents;
            state.BandHalfWidth = obj.BandHalfWidth;
            state.StartBlock = obj.StartBlock;
            state.SearchCodes = obj.SearchCodes;
            state.SearchCounts = obj.SearchCounts;
            if isempty(obj.SearchCounts)
                state.SearchModeUnwrapped = NaN;
            else
                largestCount = max(obj.SearchCounts);
                state.SearchModeUnwrapped = min( ...
                    obj.SearchCodes(obj.SearchCounts == largestCount));
            end
            state.DlevSettleEnabled = obj.DlevSettleEnabled;
            state.DlevSettleWindow = obj.DlevSettleWindow;
            state.DlevSettleTol = obj.DlevSettleTol;
            state.DlevHistoryLength = numel(obj.DlevRingValue);
            state.SettleDone = obj.SettleDone;
            state.SettleBlock = obj.SettleBlock;
            state.SnrSettleEnabled = obj.SnrSettleEnabled;
            state.SnrSettleThresholdDb = obj.SnrSettleThresholdDb;
            state.SnrSettleAlpha = obj.SnrSettleAlpha;
            state.SnrSettleMinBlock = obj.SnrSettleMinBlock;
            state.SnrEwmaDb = obj.SnrEwmaDb;
            state.SnrSettleDone = obj.SnrSettleDone;
            state.SnrSettleBlock = obj.SnrSettleBlock;
            state.FreqGateEnabled = obj.FreqGateEnabled;
            state.FreqGateWindow = obj.FreqGateWindow;
            state.FreqGateExpectedRate = obj.FreqGateExpectedRate;
            state.FreqGateMeanHalfDiffTol = obj.FreqGateMeanHalfDiffTol;
            state.FreqGateStdTol = obj.FreqGateStdTol;
            state.FreqGateRateTol = obj.FreqGateRateTol;
            state.FreqGateMinBlock = obj.FreqGateMinBlock;
            state.FreqGateDone = obj.FreqGateDone;
            state.FreqGateBlock = obj.FreqGateBlock;
            state.FreqGateSampleCount = obj.FreqGateSampleCount;
            state.FreqGateSkippedCount = obj.FreqGateSkippedCount;
        end
    end

    methods (Static)
        function [locked, diag] = detectFrequencyStateLock(freqStateSeq, ...
                windowBlocks, expectedRate, meanHalfDiffTol, stdTol, rateTol)
            %DETECTFREQUENCYSTATELOCK Flat-mean loop-frequency lock criterion.
            %
            % Under a frequency offset the timing loop tracks by holding a
            % constant nonzero integrator frequency state (code/block). This
            % offline criterion declares a lock when, over the tail window,
            % the loop frequency state is a constant: its first-half and
            % second-half means agree (<= meanHalfDiffTol), its std is small
            % (<= stdTol), and its magnitude matches the expected drift rate
            % (|mean| within rateTol of |expectedRate|). The magnitude match
            % keeps the pass/fail independent of the sign convention while the
            % returned diagnostics preserve the signed values.
            %
            % expectedRate may be NaN to skip the rate match (pure flatness),
            % and rateTol may be Inf for the same effect.
            loop_monitor.validateFiniteRealVector(freqStateSeq, ...
                'InvalidFreqSeq', 'freqStateSeq');
            loop_monitor.validateIntegerArg(windowBlocks, 1, ...
                'InvalidWindowBlocks', 'windowBlocks');
            loop_monitor.validateFiniteOrNaNScalar(expectedRate, 'expectedRate');
            loop_monitor.validateNonnegativeScalar(meanHalfDiffTol, ...
                'meanHalfDiffTol');
            loop_monitor.validateNonnegativeScalar(stdTol, 'stdTol');
            loop_monitor.validateNonnegativeScalarOrInf(rateTol, 'rateTol');

            seq = reshape(double(freqStateSeq), 1, []);
            totalLength = numel(seq);
            windowLength = min(totalLength, double(windowBlocks));
            diag = struct('WindowLength', windowLength, 'MeanValue', NaN, ...
                'MeanHalfDiff', NaN, 'TailStd', NaN, ...
                'ExpectedRate', double(expectedRate), 'RateError', NaN, ...
                'FlatnessOk', false, 'RateOk', false);
            if windowLength < 2
                locked = false;
                return;
            end

            window = seq(totalLength - windowLength + 1:end);
            half = floor(windowLength / 2);
            meanFirst = mean(window(1:half));
            meanSecond = mean(window(half + 1:end));
            diag.MeanValue = mean(window);
            diag.MeanHalfDiff = abs(meanFirst - meanSecond);
            diag.TailStd = std(window);
            diag.RateError = diag.MeanValue - double(expectedRate);
            diag.FlatnessOk = diag.MeanHalfDiff <= meanHalfDiffTol && ...
                diag.TailStd <= stdTol;
            if isnan(expectedRate) || ~isfinite(rateTol)
                diag.RateOk = true;
            else
                diag.RateOk = abs(abs(diag.MeanValue) - ...
                    abs(double(expectedRate))) <= rateTol;
            end
            locked = totalLength >= double(windowBlocks) && ...
                diag.FlatnessOk && diag.RateOk;
        end

        function [locked, diag] = detectRotationPeriodLock(unwrappedSeq, ...
                windowBlocks, codesPerUi, minIntervals, covTol, ...
                expectedPeriod, periodTol)
            %DETECTROTATIONPERIODLOCK Constant PI rotation period => tracking.
            %
            % Under a frequency offset the PI code rotates continuously; one
            % full 128-code rotation crosses one UI boundary (a UI slip). When
            % the loop is tracking, the number of blocks between successive UI
            % slips (the rotation period) is constant. This offline criterion
            % detects UI-slip events in the tail window as changes of
            % floor(unwrapped / codesPerUi), then declares a lock when there
            % are enough inter-slip intervals, their coefficient of variation
            % is small (<= covTol), and their mean matches expectedPeriod
            % (within periodTol). expectedPeriod may be NaN / periodTol Inf to
            % skip the period match. A non-rotating sequence (0 ppm) yields
            % too few events and returns locked = false; use the modal
            % center-touch criterion for the zero-offset case instead.
            if ~(isnumeric(unwrappedSeq) && isreal(unwrappedSeq) && ...
                    (isempty(unwrappedSeq) || isvector(unwrappedSeq)) && ...
                    all(isfinite(unwrappedSeq(:))))
                error('loop_monitor:InvalidUnwrappedSeq', ...
                    'unwrappedSeq must be a finite real numeric vector.');
            end
            loop_monitor.validateIntegerArg(windowBlocks, 1, ...
                'InvalidWindowBlocks', 'windowBlocks');
            loop_monitor.validateIntegerArg(codesPerUi, 2, ...
                'InvalidCodesPerUi', 'codesPerUi');
            loop_monitor.validateIntegerArg(minIntervals, 1, ...
                'InvalidMinIntervals', 'minIntervals');
            loop_monitor.validateNonnegativeScalar(covTol, 'covTol');
            loop_monitor.validateFiniteOrNaNScalar(expectedPeriod, ...
                'expectedPeriod');
            loop_monitor.validateNonnegativeScalarOrInf(periodTol, 'periodTol');

            seq = reshape(double(unwrappedSeq), 1, []);
            totalLength = numel(seq);
            windowLength = min(totalLength, double(windowBlocks));
            diag = struct('WindowLength', windowLength, 'EventCount', 0, ...
                'IntervalCount', 0, 'PeriodMean', NaN, 'PeriodStd', NaN, ...
                'PeriodCov', NaN, 'ExpectedPeriod', double(expectedPeriod), ...
                'PeriodError', NaN, 'DispersionOk', false, 'PeriodOk', false);
            if windowLength < 2
                locked = false;
                return;
            end

            window = seq(totalLength - windowLength + 1:end);
            slip = floor(window / double(codesPerUi));
            eventIndex = find(diff(slip) ~= 0) + 1;
            diag.EventCount = numel(eventIndex);
            if numel(eventIndex) < 2
                locked = false;
                return;
            end

            intervals = diff(eventIndex);
            diag.IntervalCount = numel(intervals);
            diag.PeriodMean = mean(intervals);
            diag.PeriodStd = std(intervals);
            diag.PeriodCov = diag.PeriodStd / max(abs(diag.PeriodMean), eps);
            diag.PeriodError = diag.PeriodMean - double(expectedPeriod);
            diag.DispersionOk = numel(intervals) >= double(minIntervals) && ...
                diag.PeriodCov <= covTol;
            if isnan(expectedPeriod) || ~isfinite(periodTol)
                diag.PeriodOk = true;
            else
                diag.PeriodOk = abs(diag.PeriodError) <= periodTol;
            end
            locked = totalLength >= double(windowBlocks) && ...
                diag.DispersionOk && diag.PeriodOk;
        end
    end

    methods (Static, Access = private)
        function validateIntegerArg(value, minimum, idSuffix, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value >= minimum && value == fix(value);
            if ~isValid
                error(['loop_monitor:' idSuffix], ...
                    '%s must be a finite integer scalar in its valid range.', ...
                    argumentName);
            end
        end

        function validateFiniteRealVector(value, idSuffix, argumentName)
            isValid = isnumeric(value) && isreal(value) && ...
                (isempty(value) || isvector(value)) && all(isfinite(value(:)));
            if ~isValid
                error(['loop_monitor:' idSuffix], ...
                    '%s must be a finite real numeric vector.', argumentName);
            end
        end

        function validateFiniteOrNaNScalar(value, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                (isfinite(value) || isnan(value));
            if ~isValid
                error('loop_monitor:InvalidScalar', ...
                    '%s must be a finite real scalar or NaN.', argumentName);
            end
        end

        function validateNonnegativeScalar(value, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value >= 0;
            if ~isValid
                error('loop_monitor:InvalidTolerance', ...
                    '%s must be a finite nonnegative real scalar.', argumentName);
            end
        end

        function validateNonnegativeScalarOrInf(value, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                ~isnan(value) && value >= 0;
            if ~isValid
                error('loop_monitor:InvalidTolerance', ...
                    '%s must be a nonnegative real scalar or Inf.', argumentName);
            end
        end
    end

    methods (Access = private)
        function observeSearch(obj, code, blockIndex)
            codeIndex = find(obj.SearchCodes == code, 1);
            if isempty(codeIndex)
                obj.SearchCodes(end + 1) = code;
                obj.SearchCounts(end + 1) = 1;
            else
                obj.SearchCounts(codeIndex) = obj.SearchCounts(codeIndex) + 1;
            end

            largestCount = max(obj.SearchCounts);
            obj.ModeOccurrences = largestCount;
            if largestCount < obj.MinModeOccurrences
                return;
            end

            candidates = obj.SearchCodes(obj.SearchCounts == largestCount);
            center = min(candidates);
            centerIndex = find(obj.SearchCodes == center, 1);
            obj.CenterUnwrapped = center;
            obj.CandidateStartBlock = blockIndex;
            obj.ModeOccurrences = obj.SearchCounts(centerIndex);
            obj.EventCount = 0;
            obj.HavePrevious = true;
            obj.PreviousCode = code;
            obj.SearchCodes = zeros(1, 0);
            obj.SearchCounts = zeros(1, 0);
        end

        function clearCandidateAndSearch(obj)
            obj.CenterUnwrapped = NaN;
            obj.CandidateStartBlock = NaN;
            obj.ModeOccurrences = 0;
            obj.EventCount = 0;
            obj.SearchCodes = zeros(1, 0);
            obj.SearchCounts = zeros(1, 0);
            obj.HavePrevious = false;
            obj.PreviousCode = NaN;
        end

        function slot = ringSlot(obj, blockIndex)
            slot = mod(blockIndex - 1, obj.DlevSettleWindow + 1) + 1;
        end

        function requireDlevSettleEnabled(obj, methodName)
            if ~obj.DlevSettleEnabled
                error('loop_monitor:DlevSettleDisabled', ...
                    ['%s requires the dLev settle detector; construct with ', ...
                    'dlevSettleWindow and dlevSettleTol.'], methodName);
            end
        end

        function requireSnrSettleEnabled(obj, methodName)
            if ~obj.SnrSettleEnabled
                error('loop_monitor:SnrSettleDisabled', ...
                    ['%s requires the eye-quality settle detector; call ', ...
                    'enableSnrSettle first.'], methodName);
            end
        end

        function requireFreqGateEnabled(obj, methodName)
            if ~obj.FreqGateEnabled
                error('loop_monitor:FreqGateDisabled', ...
                    ['%s requires the frequency-state lock gate; call ', ...
                    'enableFreqStateGate first.'], methodName);
            end
        end

        function validateInteger(~, value, minimum, idSuffix, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value >= minimum && value == fix(value);
            if ~isValid
                error(['loop_monitor:' idSuffix], ...
                    '%s must be a finite integer scalar in its valid range.', ...
                    argumentName);
            end
        end

        function validateTolerance(~, value)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value >= 0;
            if ~isValid
                error('loop_monitor:InvalidDlevSettleTol', ...
                    'dlevSettleTol must be a finite nonnegative real scalar.');
            end
        end

        function validateLevel(~, value, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value);
            if ~isValid
                error('loop_monitor:InvalidDlevOuter', ...
                    '%s must be a finite real scalar.', argumentName);
            end
        end
    end
end
