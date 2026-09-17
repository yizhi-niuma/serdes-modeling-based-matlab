function [locked, centerCode, diag] = detect_pi_center_touch_lock( ...
    unwrappedSeq, windowBlocks, minEvents, bandHalfWidth, codesPerUi)
%DETECT_PI_CENTER_TOUCH_LOCK Detect modal-center touch lock in a tail window.

if ~(isnumeric(unwrappedSeq) && isreal(unwrappedSeq) && ...
        (isempty(unwrappedSeq) || isvector(unwrappedSeq)) && ...
        all(isfinite(unwrappedSeq(:))) && ...
        all(unwrappedSeq(:) == fix(unwrappedSeq(:))))
    error('detect_pi_center_touch_lock:InvalidSequence', ...
        'unwrappedSeq must be a finite integer-valued real numeric vector.');
end
validateIntegerScalar(windowBlocks, 1, ...
    'detect_pi_center_touch_lock:InvalidWindowBlocks', 'windowBlocks');
validateIntegerScalar(minEvents, 1, ...
    'detect_pi_center_touch_lock:InvalidMinEvents', 'minEvents');
validateIntegerScalar(bandHalfWidth, 0, ...
    'detect_pi_center_touch_lock:InvalidBandHalfWidth', 'bandHalfWidth');
validateIntegerScalar(codesPerUi, 2, ...
    'detect_pi_center_touch_lock:InvalidCodesPerUi', 'codesPerUi');

sequence = reshape(double(unwrappedSeq), 1, []);
windowLength = min(numel(sequence), double(windowBlocks));
locked = false;
centerCode = NaN;
diag = struct('WindowStartBlock', NaN, 'WindowLength', windowLength, ...
    'CenterUnwrapped', NaN, 'CenterOccurrences', NaN, ...
    'ModeTieCount', NaN, 'FinalCount', 0, 'TotalEvents', 0, ...
    'TouchEvents', 0, 'DirectCrossEvents', 0, 'OutOfBandCount', 0, ...
    'LastResetBlock', NaN, 'OnsetBlock', NaN, ...
    'EventMask', false(1, windowLength), 'CountTrace', zeros(1, windowLength));
if windowLength == 0
    return;
end

windowStart = numel(sequence) - windowLength + 1;
tail = sequence(windowStart:end);
[uniqueCode, ~, codeGroup] = unique(tail);
occurrences = accumarray(codeGroup(:), 1);
modeCount = max(occurrences);
modeCandidates = uniqueCode(occurrences == modeCount);
center = modeCandidates(1);
centerCode = mod(center, double(codesPerUi));
diag.WindowStartBlock = windowStart;
diag.CenterUnwrapped = center;
diag.CenterOccurrences = modeCount;
diag.ModeTieCount = numel(modeCandidates);

count = 0;
havePrevious = false;
previous = NaN;
onset = NaN;
for tailIndex = 1:windowLength
    current = tail(tailIndex);
    absoluteBlock = windowStart + tailIndex - 1;
    if abs(current - center) > bandHalfWidth
        count = 0;
        havePrevious = false;
        onset = NaN;
        diag.OutOfBandCount = diag.OutOfBandCount + 1;
        diag.LastResetBlock = absoluteBlock;
    else
        if havePrevious
            isTouch = previous ~= center && current == center;
            isDirectCross = (previous - center) * (current - center) < 0;
            isEvent = isTouch || isDirectCross;
            if isEvent
                count = count + 1;
                diag.EventMask(tailIndex) = true;
                diag.TotalEvents = diag.TotalEvents + 1;
                diag.TouchEvents = diag.TouchEvents + double(isTouch);
                diag.DirectCrossEvents = diag.DirectCrossEvents + ...
                    double(isDirectCross);
                if count == minEvents
                    onset = absoluteBlock;
                end
            end
        end
        previous = current;
        havePrevious = true;
    end
    diag.CountTrace(tailIndex) = count;
end

diag.FinalCount = count;
locked = numel(sequence) >= windowBlocks && count >= minEvents;
if locked
    diag.OnsetBlock = onset;
end
end

function validateIntegerScalar(value, minimum, identifier, argumentName)
if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
        isfinite(value) && value >= minimum && value == fix(value))
    error(identifier, '%s must be an integer scalar greater than or equal to %d.', ...
        argumentName, minimum);
end
end
