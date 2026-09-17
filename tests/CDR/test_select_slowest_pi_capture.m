function test_select_slowest_pi_capture
%TEST_SELECT_SLOWEST_PI_CAPTURE Regression checks for first-capture selection.
thisFile = mfilename('fullpath');
repoRoot = fileparts(fileparts(fileparts(thisFile)));
addpath(fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe'));
checkEventRules(); checkResetBeforeCapture(); checkFirstCaptureIsSticky();
checkFinalLockEligibility(); checkTie(); checkNoEligible(); checkFullHistory();
checkShiftAndFlagShapes(); checkInvalidInputs();
fprintf('test_select_slowest_pi_capture passed 9 / 9 checks.\n');
end

function checkEventRules
trace = [1 0 0 1 0 0; -1 1 -1 -1 -1 -1; -1 0 0 1 0 0];
[first, slowest] = select_slowest_pi_capture(trace, [0 0 0], true(3, 1), 2, 3);
assert(isequal(first, [5 3 5]) && slowest == 1);
% Inclusive boundaries are in-band and each return to center is one touch.
[first, slowest] = select_slowest_pi_capture([10 7 10 13 10], 10, true, 2, 3);
assert(first == 5 && slowest == 1);
end

function checkResetBeforeCapture
trace = [10 9 10 10 10 14 10 9 10 9 10];
[first, slowest] = select_slowest_pi_capture(trace, 10, true, 2, 3);
assert(first == 11 && slowest == 1); % Block 6 resets count and predecessor.
end

function checkFirstCaptureIsSticky
trace = [0 1 0 1 0 9 0 1 0];
[first, slowest] = select_slowest_pi_capture(trace, 0, true, 2, 3);
assert(first == 5 && slowest == 1); % Later reset cannot replace first capture.
end

function checkFinalLockEligibility
trace = [0 1 0 1 0 0 0; 0 0 1 0 1 0 0; 0 0 0 1 0 1 0];
[first, slowest] = select_slowest_pi_capture(trace, zeros(3, 1), ...
    [true false true], 2, 3);
assert(isequal(first, [5 6 7]) && slowest == 3);
assert(isfinite(first(2))); % Unlocked rows still report their first capture.
end

function checkTie
trace = repmat([0 1 0 1 0], 3, 1);
[first, slowest] = select_slowest_pi_capture(trace, [0; 0; 0], true(1, 3), 2, 1);
assert(isequal(first, [5 5 5]) && slowest == 1);
end

function checkNoEligible
trace = [0 1 0 0; 0 0 0 0];
[first, slowest] = select_slowest_pi_capture(trace, [0 0], [false true], 1, 1);
assert(isequaln(first, [3 NaN]) && isnan(slowest));
[first, slowest] = select_slowest_pi_capture(zeros(2, 4), [0; 0], true(2, 1), 1, 0);
assert(all(isnan(first)) && isnan(slowest));
end

function checkFullHistory
prefix = touchSequence(20, 51);
trace = [prefix repmat(20, 1, 2200 - numel(prefix))];
[first, slowest] = select_slowest_pi_capture(trace, 20, true, 51, 3);
assert(first == 103 && slowest == 1 && first < numel(trace) - 2000 + 1);
end

function checkShiftAndFlagShapes
base = [-6 -5 -6 -5 -6; -9 -8 -9 -8 -9];
[firstRow, indexRow] = select_slowest_pi_capture(base, [-6 -9], [1 1], 2, 1);
[firstCol, indexCol] = select_slowest_pi_capture(base - 256, [-262; -265], [1; 1], 2, 1);
assert(isequal(firstRow, [5 5]) && isequal(firstCol, firstRow));
assert(indexRow == 1 && indexCol == 1);
end

function checkInvalidInputs
valid = [0 1; 1 0]; centers = [0; 0]; flags = [true; true];
cases = {@() select_slowest_pi_capture([], 0, true, 1, 1), ...
    @() select_slowest_pi_capture([0 NaN], 0, true, 1, 1), ...
    @() select_slowest_pi_capture([0 1.5], 0, true, 1, 1), ...
    @() select_slowest_pi_capture([0 1i], 0, true, 1, 1), ...
    @() select_slowest_pi_capture(valid, 0, flags, 1, 1), ...
    @() select_slowest_pi_capture(valid, [0; NaN], flags, 1, 1), ...
    @() select_slowest_pi_capture(valid, centers, true, 1, 1), ...
    @() select_slowest_pi_capture(valid, centers, [true; 2], 1, 1), ...
    @() select_slowest_pi_capture(valid, centers, flags, 0, 1), ...
    @() select_slowest_pi_capture(valid, centers, flags, 1.5, 1), ...
    @() select_slowest_pi_capture(valid, centers, flags, 1, -1), ...
    @() select_slowest_pi_capture(valid, centers, flags, 1, 1.5)};
ids = {'InvalidTrace','InvalidTrace','InvalidTrace','InvalidTrace', ...
    'InvalidCenter','InvalidCenter','InvalidFinalLockedFlag', ...
    'InvalidFinalLockedFlag','InvalidMinEvents','InvalidMinEvents', ...
    'InvalidBandHalfWidth','InvalidBandHalfWidth'};
for k = 1:numel(cases)
    assertThrows(cases{k}, ['select_slowest_pi_capture:' ids{k}]);
end
end

function sequence = touchSequence(center, count)
sequence = [center repmat([center + 1 center], 1, count)];
end

function assertThrows(action, identifier)
try, action(); catch err, assert(strcmp(err.identifier, identifier)); return; end
error('Expected error %s was not thrown.', identifier);
end
