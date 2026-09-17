classdef ffe_freeze_monitor < handle
    %FFE_FREEZE_MONITOR Causal block-rate detector for permanent FFE freeze.
    %
    % The monitor has three states. Before StartBlock, samples are ignored.
    % SEARCH then counts each observed unwrapped PI code once and qualifies
    % the lowest-valued mode when its count reaches MinModeOccurrences.
    % CANDIDATE fixes that mode as CenterUnwrapped and counts center touches
    % and strict side-to-side crossings inside the inclusive center band.
    % An outlier abandons the candidate and clears all SEARCH history; the
    % outlier itself is not the first sample of the new search. Reaching
    % MinEvents enters FROZEN permanently. update returns true only on that
    % transition. No sample trace is retained, only sparse SEARCH counts.

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
    end

    properties (Access = private)
        SearchCodes = zeros(1, 0)
        SearchCounts = zeros(1, 0)
        HavePrevious = false
        PreviousCode = NaN
    end

    methods
        function obj = ffe_freeze_monitor(minModeOccurrences, minEvents, ...
                bandHalfWidth, startBlock)
            %FFE_FREEZE_MONITOR Construct a monitor with explicit thresholds.
            if nargin ~= 4
                error('ffe_freeze_monitor:InvalidConstructor', ...
                    ['Expected minModeOccurrences, minEvents, ', ...
                    'bandHalfWidth, and startBlock.']);
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
        end

        function triggered = update(obj, unwrappedCode, blockIndex)
            %UPDATE Observe one block and report only the freeze transition.
            obj.validateInteger(unwrappedCode, -Inf, ...
                'InvalidCode', 'unwrappedCode');
            obj.validateInteger(blockIndex, 1, ...
                'InvalidBlock', 'blockIndex');
            blockIndex = double(blockIndex);
            if ~isnan(obj.LastBlock) && blockIndex <= obj.LastBlock
                error('ffe_freeze_monitor:NonMonotonicBlock', ...
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

        function validateInteger(~, value, minimum, idSuffix, argumentName)
            isValid = isnumeric(value) && isreal(value) && isscalar(value) && ...
                isfinite(value) && value >= minimum && value == fix(value);
            if ~isValid
                error(['ffe_freeze_monitor:' idSuffix], ...
                    '%s must be a finite integer scalar in its valid range.', ...
                    argumentName);
            end
        end
    end
end
