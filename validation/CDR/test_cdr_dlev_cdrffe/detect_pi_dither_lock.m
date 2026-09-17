function [locked, centerCode, maxTransitions, tailTransitions, ...
    onsetBlock, tailStartBlock, codePair] = ...
    detect_pi_dither_lock(unwrappedSeq, minTransitions, codesPerUi)
%DETECT_PI_DITHER_LOCK Detect terminal two-code PI dither lock.
%   [LOCKED, CENTERCODE, MAXTRANSITIONS, TAILTRANSITIONS, ONSETBLOCK,
%   TAILSTARTBLOCK, CODEPAIR] = DETECT_PI_DITHER_LOCK(UNWRAPPEDSEQ,
%   MINTRANSITIONS, CODESPERUI) applies the PI lock criterion to one phase
%   trace. UNWRAPPEDSEQ must be uiSlip*CODESPERUI + wrappedCode; using a
%   naively wrapped trace would hide whole-UI slips.
%
%   The terminal candidate segment must remain within one fixed pair of
%   adjacent unwrapped codes and contain at least MINTRANSITIONS actual
%   jumps between the two codes. Zero steps (dwell) preserve the candidate
%   without increasing or resetting its jump count. Changing to another
%   adjacent pair starts a new candidate at the beginning of the preceding
%   dwell, while a jump of two or more codes clears the candidate. Only the
%   candidate that reaches the end of the trace can set LOCKED; an earlier
%   qualifying segment is diagnostic history only.
%
%   Outputs:
%     LOCKED          - true only when the terminal candidate qualifies.
%     CENTERCODE      - wrapped upper member of the adjacent unwrapped pair
%                       when locked, otherwise NaN.
%     MAXTRANSITIONS  - largest historical jump count within any one
%                       continuous fixed-pair candidate segment.
%     TAILTRANSITIONS - jump count of the terminal candidate, or zero when
%                       the trace ends without an adjacent-pair candidate.
%     ONSETBLOCK      - block where the terminal candidate first reaches
%                       MINTRANSITIONS, or NaN when unlocked.
%     TAILSTARTBLOCK  - first block of the terminal candidate, including
%                       any leading dwell before its first jump; NaN if no
%                       terminal pair is available.
%     CODEPAIR        - terminal adjacent pair as wrapped codes, ordered by
%                       the lower then upper unwrapped code; [NaN NaN] when
%                       no terminal pair is available. Thus unwrapped
%                       pairs 127/128 and -1/0 both report [127 0] for a
%                       128-code UI.

if ~(isnumeric(unwrappedSeq) && isreal(unwrappedSeq) && ...
        (isempty(unwrappedSeq) || isvector(unwrappedSeq)) && ...
        all(isfinite(unwrappedSeq(:))) && ...
        all(unwrappedSeq(:) == fix(unwrappedSeq(:))))
    error('detect_pi_dither_lock:InvalidSequence', ...
        'unwrappedSeq must be a finite integer-valued real numeric vector.');
end
if ~(isnumeric(minTransitions) && isreal(minTransitions) && ...
        isscalar(minTransitions) && isfinite(minTransitions) && ...
        minTransitions >= 1 && minTransitions == fix(minTransitions))
    error('detect_pi_dither_lock:InvalidMinTransitions', ...
        'minTransitions must be a positive integer scalar.');
end
if ~(isnumeric(codesPerUi) && isreal(codesPerUi) && ...
        isscalar(codesPerUi) && isfinite(codesPerUi) && ...
        codesPerUi >= 2 && codesPerUi == fix(codesPerUi))
    error('detect_pi_dither_lock:InvalidCodesPerUi', ...
        'codesPerUi must be an integer scalar greater than or equal to two.');
end

sequence = reshape(double(unwrappedSeq), 1, []);
locked = false;
centerCode = NaN;
maxTransitions = 0;
tailTransitions = 0;
onsetBlock = NaN;
tailStartBlock = NaN;
codePair = [NaN NaN];

if numel(sequence) < 2
    return;
end

activePair = [NaN NaN];
activeTransitions = 0;
activeStartBlock = NaN;
activeOnsetBlock = NaN;
dwellStartBlock = 1;

for blockIndex = 2:numel(sequence)
    step = sequence(blockIndex) - sequence(blockIndex - 1);
    if step == 0
        % Dwell belongs to the current candidate and does not change count.
        continue;
    end

    if abs(step) == 1
        nextPair = sort(sequence(blockIndex - 1:blockIndex));
        if all(nextPair == activePair)
            activeTransitions = activeTransitions + 1;
        else
            % The preceding equal-code run is the leading dwell of the new
            % pair, including when this jump leaves a different pair.
            activePair = nextPair;
            activeTransitions = 1;
            activeStartBlock = dwellStartBlock;
            activeOnsetBlock = NaN;
        end
        if activeTransitions == minTransitions
            activeOnsetBlock = blockIndex;
        end
        maxTransitions = max(maxTransitions, activeTransitions);
    else
        activePair = [NaN NaN];
        activeTransitions = 0;
        activeStartBlock = NaN;
        activeOnsetBlock = NaN;
    end

    % Every nonzero step begins a new dwell at the arriving code.
    dwellStartBlock = blockIndex;
end

if all(isfinite(activePair))
    tailTransitions = activeTransitions;
    tailStartBlock = activeStartBlock;
    codePair = mod(activePair, double(codesPerUi));
    locked = activeTransitions >= minTransitions;
    if locked
        centerCode = mod(activePair(2), double(codesPerUi));
        onsetBlock = activeOnsetBlock;
    end
end
end
