function test_detect_pi_dither_lock
%TEST_DETECT_PI_DITHER_LOCK Regression checks for terminal PI dither lock.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
suiteRoot = fullfile(repoRoot, 'validation', 'CDR', 'test_cdr_dlev_cdrffe');
addpath(suiteRoot);
setup_cdr_dlev_cdrffe_paths('legacy');

checkExactTransitionThreshold();
checkDwellHandling();
checkNonDitherMotion();
checkTerminalOnlyQualification();
checkResetAndRelock();
checkUnwrappedRingPairs();
checkShapeEmptyAndMetadata();
checkInvalidInput();
checkFixedSeedOracle();

fprintf('test_detect_pi_dither_lock passed 9 / 9 checks.\n');
end

function checkExactTransitionThreshold()
seq50 = alternatingPair(20, 21, 50);
[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock(seq50, 51, 128);
assert(~locked);
assert(isnan(centerCode));
assert(maxCount == 50 && tailCount == 50);
assert(isnan(onset) && tailStart == 1);
assert(isequal(pair, [20 21]));

seq51 = alternatingPair(20, 21, 51);
[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock(seq51, 51, 128);
assert(locked);
assert(centerCode == 21);
assert(maxCount == 51 && tailCount == 51);
assert(onset == 52 && tailStart == 1);
assert(isequal(pair, [20 21]));
end

function checkDwellHandling()
base = alternatingPair(30, 31, 51);
% Repeat every visited code for a different dwell duration. Only changes
% between adjacent runs count, not the repeated blocks inside each run.
seq = repelem(base, mod(0:numel(base) - 1, 4) + 1);
seq = [repmat(seq(1), 1, 5), seq, repmat(seq(end), 1, 200)];
[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock(seq, 51, 128);
expectedOnset = find(cumsum([false abs(diff(seq)) == 1]) == 51, 1);
assert(locked && centerCode == 31);
assert(maxCount == 51 && tailCount == 51);
assert(onset == expectedOnset);
assert(tailStart == 1);
assert(isequal(pair, [30 31]));

% Dwells do not manufacture transitions.
seq = repelem([40 41 40 41], [20 30 40 500]);
[locked, ~, maxCount, tailCount] = detect_pi_dither_lock(seq, 4, 128);
assert(~locked && maxCount == 3 && tailCount == 3);
end

function checkNonDitherMotion()
[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock(ones(1, 500) * 17, 2, 128);
assert(~locked && isnan(centerCode));
assert(maxCount == 0 && tailCount == 0 && isnan(onset));
assert(isnan(tailStart) && all(isnan(pair)));

% Every +1 step changes the fixed pair, so monotonic motion never builds a
% transition count, with or without dwell between steps.
for seq = {0:200, repelem(0:80, 3)}
    [locked, ~, maxCount, tailCount, ~, tailStart, pair] = ...
        detect_pi_dither_lock(seq{1}, 2, 128);
    assert(~locked && maxCount == 1 && tailCount == 1);
    assert(isfinite(tailStart) && all(isfinite(pair)));
end

% Repeated three-code motion cannot retain transitions from both pairs.
seq = repmat([10 11 12 11], 1, 80);
[locked, ~, maxCount, tailCount] = detect_pi_dither_lock(seq, 3, 128);
assert(~locked && maxCount <= 2 && tailCount <= 2);
end

function checkTerminalOnlyQualification()
qualified = alternatingPair(5, 6, 55);
seq = [qualified, 20, alternatingPair(30, 31, 10)];
[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock(seq, 51, 128);
assert(~locked && isnan(centerCode));
assert(maxCount == 55 && tailCount == 10 && isnan(onset));
assert(tailStart == numel(qualified) + 2);
assert(isequal(pair, [30 31]));

% A qualifying terminal pair stays locked through an arbitrarily long
% final dwell; there is deliberately no timeout.
seq = [qualified, repmat(qualified(end), 1, 1000)];
[locked, ~, maxCount, tailCount, onset] = ...
    detect_pi_dither_lock(seq, 51, 128);
assert(locked && maxCount == 55 && tailCount == 55 && onset == 52);
end

function checkResetAndRelock()
first = alternatingPair(8, 9, 60);
second = alternatingPair(40, 41, 51);
seq = [first, 25, 25, 25, second];
[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock(seq, 51, 128);
secondStart = numel(first) + 4;
assert(locked && centerCode == 41);
assert(maxCount == 60 && tailCount == 51);
assert(tailStart == secondStart);
assert(onset == secondStart + 51);
assert(isequal(pair, [40 41]));

% A >=2 jump clears the pair. Ending in a constant dwell has no inferred
% pair metadata and cannot inherit the earlier qualification.
seq = [first, 50, 50, 50];
[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock(seq, 51, 128);
assert(~locked && isnan(centerCode) && maxCount == 60 && tailCount == 0);
assert(isnan(onset) && isnan(tailStart) && all(isnan(pair)));
end

function checkUnwrappedRingPairs()
seq = alternatingPair(127, 128, 51);
[locked, centerCode, ~, tailCount, ~, ~, pair] = ...
    detect_pi_dither_lock(seq, 51, 128);
assert(locked && centerCode == 0 && tailCount == 51);
assert(isequal(pair, [127 0]));

seq = alternatingPair(-1, 0, 51);
[locked, centerCode, ~, tailCount, ~, ~, pair] = ...
    detect_pi_dither_lock(seq, 51, 128);
assert(locked && centerCode == 0 && tailCount == 51);
assert(isequal(pair, [127 0]));

% The reported center and wrapped pair are invariant to whole-UI shifts.
for shiftedPair = {[-257 -256], [-129 -128], [-1 0], ...
        [127 128], [255 256]}
    seq = alternatingPair(shiftedPair{1}(1), shiftedPair{1}(2), 51);
    [locked, centerCode, ~, tailCount, ~, ~, pair] = ...
        detect_pi_dither_lock(seq, 51, 128);
    assert(locked && centerCode == 0 && tailCount == 51);
    assert(isequal(pair, [127 0]));
end

% Whole-UI slips and motion beyond a full UI remain visible in unwrapped
% space and must not resemble an adjacent wrapped-code pair.
seq = [alternatingPair(127, 128, 51), 256, 256, 256];
[locked, ~, maxCount, tailCount, ~, tailStart, pair] = ...
    detect_pi_dither_lock(seq, 51, 128);
assert(~locked && maxCount == 51 && tailCount == 0);
assert(isnan(tailStart) && all(isnan(pair)));

seq = 0:300;
[locked, ~, maxCount, tailCount] = detect_pi_dither_lock(seq, 2, 128);
assert(~locked && maxCount == 1 && tailCount == 1);
end

function checkShapeEmptyAndMetadata()
row = [7 7 alternatingPair(7, 8, 7) 8 8];
rowResult = cell(1, 7);
columnResult = cell(1, 7);
[rowResult{:}] = detect_pi_dither_lock(row, 7, 16);
[columnResult{:}] = detect_pi_dither_lock(row.', 7, 16);
assert(isequaln(rowResult, columnResult));
assert(rowResult{1} && rowResult{6} == 1);
assert(isequal(rowResult{7}, [7 8]));

[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock([], 1, 128);
assert(~locked && isnan(centerCode));
assert(maxCount == 0 && tailCount == 0);
assert(isnan(onset) && isnan(tailStart) && all(isnan(pair)));

% An insufficient terminal pair still reports useful tail metadata.
[locked, centerCode, maxCount, tailCount, onset, tailStart, pair] = ...
    detect_pi_dither_lock([4 4 5 5], 2, 128);
assert(~locked && isnan(centerCode));
assert(maxCount == 1 && tailCount == 1 && isnan(onset));
assert(tailStart == 1 && isequal(pair, [4 5]));
end

function checkInvalidInput()
assertThrowsId(@() detect_pi_dither_lock([1 2; 3 4], 2, 128), ...
    'detect_pi_dither_lock:InvalidSequence');
assertThrowsId(@() detect_pi_dither_lock([1 NaN], 2, 128), ...
    'detect_pi_dither_lock:InvalidSequence');
assertThrowsId(@() detect_pi_dither_lock([1 Inf], 2, 128), ...
    'detect_pi_dither_lock:InvalidSequence');
assertThrowsId(@() detect_pi_dither_lock([1 1.5], 2, 128), ...
    'detect_pi_dither_lock:InvalidSequence');
assertThrowsId(@() detect_pi_dither_lock([1 1i], 2, 128), ...
    'detect_pi_dither_lock:InvalidSequence');
assertThrowsId(@() detect_pi_dither_lock([1 2], 0, 128), ...
    'detect_pi_dither_lock:InvalidMinTransitions');
assertThrowsId(@() detect_pi_dither_lock([1 2], 1.5, 128), ...
    'detect_pi_dither_lock:InvalidMinTransitions');
assertThrowsId(@() detect_pi_dither_lock([1 2], [1 2], 128), ...
    'detect_pi_dither_lock:InvalidMinTransitions');
assertThrowsId(@() detect_pi_dither_lock([1 2], 1, 1), ...
    'detect_pi_dither_lock:InvalidCodesPerUi');
assertThrowsId(@() detect_pi_dither_lock([1 2], 1, 2.5), ...
    'detect_pi_dither_lock:InvalidCodesPerUi');
end

function checkFixedSeedOracle()
old = rng;
cleanup = onCleanup(@() rng(old));
rng(92817, 'twister');
for trial = 1:1000
    sequenceLength = randi([0 120]);
    if sequenceLength == 0
        seq = [];
    else
        stepAlphabet = [-3 -2 -1 0 0 0 1 2 3];
        step = stepAlphabet(randi(numel(stepAlphabet), ...
            1, sequenceLength - 1));
        seq = [randi([-20 20]), zeros(1, sequenceLength - 1)];
        if sequenceLength > 1
            seq(2:end) = seq(1) + cumsum(step);
        end
    end
    minTransitions = randi([1 8]);
    codesPerUi = randi([2 16]);

    actual = cell(1, 7);
    expected = cell(1, 7);
    [actual{:}] = detect_pi_dither_lock(seq, minTransitions, codesPerUi);
    [expected{:}] = oracleDetector(seq, minTransitions, codesPerUi);
    assert(isequaln(actual, expected), ...
        'Random oracle mismatch on trial %d.', trial);
end
end

function seq = alternatingPair(lowerCode, upperCode, transitionCount)
seq = zeros(1, transitionCount + 1);
seq(1:2:end) = lowerCode;
seq(2:2:end) = upperCode;
end

function [locked, centerCode, maxTransitions, tailTransitions, ...
    onsetBlock, tailStartBlock, codePair] = ...
    oracleDetector(sequence, minTransitions, codesPerUi)
% Deliberately simple O(n^3) suffix/segment enumerator, independent of the
% production state machine. A valid candidate contains exactly two adjacent
% integer values, and every code in the segment belongs to that fixed pair.
sequence = reshape(double(sequence), 1, []);
n = numel(sequence);
maxTransitions = 0;
for first = 1:n
    for last = first + 1:n
        segment = sequence(first:last);
        if max(segment) - min(segment) == 1
            maxTransitions = max(maxTransitions, sum(abs(diff(segment)) == 1));
        end
    end
end

tailStartBlock = NaN;
tailTransitions = 0;
codePair = [NaN NaN];
for first = 1:max(n - 1, 0)
    segment = sequence(first:n);
    if max(segment) - min(segment) == 1
        tailStartBlock = first;
        tailTransitions = sum(abs(diff(segment)) == 1);
        unwrappedPair = [min(segment) max(segment)];
        codePair = mod(unwrappedPair, codesPerUi);
        break;
    end
end

locked = tailTransitions >= minTransitions;
centerCode = NaN;
onsetBlock = NaN;
if locked
    unwrappedPair = [min(sequence(tailStartBlock:n)), ...
        max(sequence(tailStartBlock:n))];
    centerCode = mod(unwrappedPair(2), codesPerUi);
    jumpBlocks = find(abs(diff(sequence(tailStartBlock:n))) == 1) + ...
        tailStartBlock;
    onsetBlock = jumpBlocks(minTransitions);
end
end

function assertThrowsId(testFcn, expectedId)
didThrow = false;
try
    testFcn();
catch err
    didThrow = true;
    assert(strcmp(err.identifier, expectedId), ...
        'Expected error %s, received %s.', expectedId, err.identifier);
end
assert(didThrow, 'Expected error %s was not thrown.', expectedId);
end
