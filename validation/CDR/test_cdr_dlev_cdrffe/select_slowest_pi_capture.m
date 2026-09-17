function [firstCaptureBlock, slowestIndex] = select_slowest_pi_capture( ...
    unwrappedPhaseTrace, centerUnwrapped, finalLockedFlag, minEvents, bandHalfWidth)
%SELECT_SLOWEST_PI_CAPTURE Select the finally locked row with latest first capture.
%   Rows are starts and columns are trajectory blocks. A capture event is an
%   arrival at the row's fixed center from a noncenter code, or a direct
%   crossing from one side of that center to the other. Values outside the
%   inclusive center +/- band reset the event count and previous sample.
%   FIRSTCAPTUREBLOCK records the first threshold block for every row,
%   including rows whose FINALLOCKEDFLAG is false. SLOWESTINDEX considers
%   only finally locked rows and resolves equal capture blocks by first row.

if ~(isnumeric(unwrappedPhaseTrace) && isreal(unwrappedPhaseTrace) && ...
        ismatrix(unwrappedPhaseTrace) && ~isempty(unwrappedPhaseTrace) && ...
        all(isfinite(unwrappedPhaseTrace(:))) && ...
        all(unwrappedPhaseTrace(:) == fix(unwrappedPhaseTrace(:))))
    error('select_slowest_pi_capture:InvalidTrace', ...
        'unwrappedPhaseTrace must be a nonempty finite integer-valued real numeric matrix.');
end
rowCount = size(unwrappedPhaseTrace, 1);
if ~(isnumeric(centerUnwrapped) && isreal(centerUnwrapped) && ...
        isvector(centerUnwrapped) && numel(centerUnwrapped) == rowCount && ...
        all(isfinite(centerUnwrapped(:))) && ...
        all(centerUnwrapped(:) == fix(centerUnwrapped(:))))
    error('select_slowest_pi_capture:InvalidCenter', ...
        'centerUnwrapped must contain one finite integer-valued center per row.');
end
if ~((islogical(finalLockedFlag) || isnumeric(finalLockedFlag)) && ...
        isreal(finalLockedFlag) && isvector(finalLockedFlag) && ...
        numel(finalLockedFlag) == rowCount && ...
        all(isfinite(finalLockedFlag(:))) && ...
        all(finalLockedFlag(:) == 0 | finalLockedFlag(:) == 1))
    error('select_slowest_pi_capture:InvalidFinalLockedFlag', ...
        'finalLockedFlag must contain one logical or zero/one value per row.');
end
validateIntegerScalar(minEvents, 1, ...
    'select_slowest_pi_capture:InvalidMinEvents', 'minEvents');
validateIntegerScalar(bandHalfWidth, 0, ...
    'select_slowest_pi_capture:InvalidBandHalfWidth', 'bandHalfWidth');

trace = double(unwrappedPhaseTrace);
centers = double(centerUnwrapped(:));
firstCaptureBlock = nan(1, rowCount);
for rowIndex = 1:rowCount
    count = 0;
    havePrevious = false;
    center = centers(rowIndex);
    for blockIndex = 1:size(trace, 2)
        current = trace(rowIndex, blockIndex);
        if abs(current - center) > bandHalfWidth
            count = 0;
            havePrevious = false;
        else
            if havePrevious
                isTouch = previous ~= center && current == center;
                isDirectCross = (previous - center) * (current - center) < 0;
                if isTouch || isDirectCross
                    count = count + 1;
                    if count >= minEvents
                        firstCaptureBlock(rowIndex) = blockIndex;
                        break;
                    end
                end
            end
            previous = current;
            havePrevious = true;
        end
    end
end

eligible = find(logical(finalLockedFlag(:)).' & isfinite(firstCaptureBlock));
slowestIndex = NaN;
if ~isempty(eligible)
    [~, position] = max(firstCaptureBlock(eligible));
    slowestIndex = eligible(position);
end
end

function validateIntegerScalar(value, minimum, identifier, argumentName)
if ~(isnumeric(value) && isreal(value) && isscalar(value) && ...
        isfinite(value) && value >= minimum && value == fix(value))
    error(identifier, '%s must be an integer scalar greater than or equal to %d.', ...
        argumentName, minimum);
end
end
