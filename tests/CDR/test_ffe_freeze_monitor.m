function test_ffe_freeze_monitor
%TEST_FFE_FREEZE_MONITOR Regression checks for causal FFE freeze detection.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
addpath(fullfile(repoRoot, 'validation', 'CDR', ...
    'test_cdr_dlev_cdrffe'));

testStartAndQualificationBoundaries();
testExactProductionThresholds();
testLatchedCenterAndModeTie();
testEventDefinitionsAndBandExit();
testResetStartsFreshNextBlock();
testPermanentFreeze();
testCausalityAndIndependentInstances();
testUnwrappedCodesRemainDistinct();
testInvalidInputs();

fprintf('test_ffe_freeze_monitor passed 9 / 9 checks.\n');
end

function testStartAndQualificationBoundaries()
monitor = ffe_freeze_monitor(3, 1, 1, 4);
for block = 1:3
    assert(~monitor.update(5, block));
end
state = monitor.getState();
assert(state.ModeOccurrences == 0 && isempty(state.SearchCodes));
assert(isnan(state.CenterUnwrapped) && state.LastBlock == 3);

assert(~monitor.update(5, 4));
assert(~monitor.update(5, 5));
assert(isnan(monitor.getState().CenterUnwrapped));
assert(~monitor.update(5, 6));
state = monitor.getState();
assert(state.CenterUnwrapped == 5);
assert(state.CandidateStartBlock == 6);
assert(state.ModeOccurrences == 3 && state.EventCount == 0);
assert(~monitor.update(4, 7));             % center departure
assert(monitor.update(5, 8));              % noncenter-to-center touch
assert(monitor.Frozen && monitor.FreezeBlock == 8);
end

function testExactProductionThresholds()
monitor = ffe_freeze_monitor(100, 50, 3, 1);
for block = 1:99
    assert(~monitor.update(7, block));
end
assert(isnan(monitor.CenterUnwrapped));
assert(~monitor.update(7, 100));
state = monitor.getState();
assert(state.CenterUnwrapped == 7 && state.ModeOccurrences == 100);
assert(state.EventCount == 0 && state.CandidateStartBlock == 100);

for event = 1:49
    departureBlock = 100 + 2 * event - 1;
    assert(~monitor.update(8, departureBlock));
    assert(~monitor.update(7, departureBlock + 1));
end
state = monitor.getState();
assert(~state.Frozen && state.EventCount == 49);
assert(~monitor.update(8, 199));
assert(monitor.update(7, 200));
state = monitor.getState();
assert(state.Frozen && state.EventCount == 50);
assert(state.FreezeBlock == 200 && state.ModeOccurrences == 150);
end

function testLatchedCenterAndModeTie()
monitor = ffe_freeze_monitor(4, 20, 3, 1);
feed(monitor, [11 12 12 11], 1);
state = monitor.getState();
assert(isnan(state.CenterUnwrapped));
assert(state.SearchModeUnwrapped == 11);   % equal counts choose lower code
assert(isequal(sort(state.SearchCodes), [11 12]));

assert(~monitor.update(12, 5));
assert(~monitor.update(12, 6));
state = monitor.getState();
assert(state.CenterUnwrapped == 12 && state.ModeOccurrences == 4);
feed(monitor, [11 11 11 12 11], 7);
state = monitor.getState();
assert(state.CenterUnwrapped == 12);       % later distribution cannot move it
assert(state.ModeOccurrences == 5);       % only later center samples increment
end

function testEventDefinitionsAndBandExit()
monitor = ffe_freeze_monitor(3, 99, 3, 1);
feed(monitor, [10 10 10], 1);
codes = [11 10 10 11 9 9 10 11 7];
expectedEvents = [0 1 1 1 2 2 3 3 4];
for index = 1:numel(codes)
    assert(~monitor.update(codes(index), index + 3));
    assert(monitor.EventCount == expectedEvents(index));
end
% Covered above: departure and dwell do not count, a center touch counts,
% 11->9 is a strict crossing, and 11->7 crosses at the inclusive edge.
assert(~monitor.update(14, 13));           % outside [7, 13]
state = monitor.getState();
assert(state.ResetCount == 1 && state.EventCount == 0);
assert(isnan(state.CenterUnwrapped) && isempty(state.SearchCodes));
end

function testResetStartsFreshNextBlock()
monitor = ffe_freeze_monitor(3, 2, 1, 1);
feed(monitor, [4 4 5 4], 1);
assert(monitor.CenterUnwrapped == 4);
assert(~monitor.update(3, 5));
assert(~monitor.update(6, 6));             % outlier is discarded
state = monitor.getState();
assert(state.ResetCount == 1 && state.ModeOccurrences == 0);
assert(isempty(state.SearchCodes) && isnan(state.CandidateStartBlock));

assert(~monitor.update(4, 7));
state = monitor.getState();
assert(isequal(state.SearchCodes, 4));
assert(isequal(state.SearchCounts, 1));    % neither old counts nor code 6 seeded
assert(~monitor.update(4, 8));
assert(~monitor.update(4, 9));
assert(monitor.CandidateStartBlock == 9);
end

function testPermanentFreeze()
monitor = ffe_freeze_monitor(3, 1, 1, 1);
feed(monitor, [0 0 0 1], 1);
assert(monitor.update(0, 5));
before = monitor.getState();
assert(~monitor.update(1000, 6));
after = monitor.getState();
fields = {'Frozen', 'FreezeBlock', 'CenterUnwrapped', ...
    'CandidateStartBlock', 'ModeOccurrences', 'EventCount', 'ResetCount'};
for index = 1:numel(fields)
    assert(isequaln(before.(fields{index}), after.(fields{index})));
end
assert(after.LastBlock == 6 && after.ResetCount == 0);
end

function testCausalityAndIndependentInstances()
left = ffe_freeze_monitor(3, 2, 1, 1);
right = ffe_freeze_monitor(3, 2, 1, 1);
prefix = [4 4 4 5];
for block = 1:numel(prefix)
    assert(left.update(prefix(block), block) == ...
        right.update(prefix(block), block));
end
assert(isequaln(left.getState(), right.getState()));

assert(~left.update(4, 5));                % event one
assert(~left.update(5, 6));
assert(left.update(4, 7));                 % future A freezes
assert(~right.update(8, 5));               % future B resets instead
assert(~right.Frozen && right.ResetCount == 1);
assert(left.Frozen && left.ResetCount == 0);

untouched = ffe_freeze_monitor(3, 1, 1, 1);
assert(isnan(untouched.LastBlock));         % distinct handle has no shared state
end

function testUnwrappedCodesRemainDistinct()
base = ffe_freeze_monitor(3, 1, 1, 1);
shifted = ffe_freeze_monitor(3, 1, 1, 1);
baseCodes = [-2 -2 -2 -1 -2];
for block = 1:numel(baseCodes)
    baseTrigger = base.update(baseCodes(block), block);
    shiftedTrigger = shifted.update(baseCodes(block) + 2048, block);
    assert(baseTrigger == shiftedTrigger);
end
assert(base.CenterUnwrapped == -2);
assert(shifted.CenterUnwrapped == 2046);
assert(base.EventCount == shifted.EventCount && shifted.Frozen);

noAlias = ffe_freeze_monitor(2, 2, 200, 1);
assert(~noAlias.update(0, 1));
assert(~noAlias.update(128, 2));
state = noAlias.getState();
assert(isequal(state.SearchCodes, [0 128]));
assert(isequal(state.SearchCounts, [1 1]));
assert(state.SearchModeUnwrapped == 0);
assert(~noAlias.update(0, 3));
assert(noAlias.CenterUnwrapped == 0);       % 128 was not wrapped onto zero
end

function testInvalidInputs()
assertThrowsId(@() ffe_freeze_monitor(0, 1, 0, 1), ...
    'ffe_freeze_monitor:InvalidMinModeOccurrences');
assertThrowsId(@() ffe_freeze_monitor(1, 1.5, 0, 1), ...
    'ffe_freeze_monitor:InvalidMinEvents');
assertThrowsId(@() ffe_freeze_monitor(1, 1, -1, 1), ...
    'ffe_freeze_monitor:InvalidBandHalfWidth');
assertThrowsId(@() ffe_freeze_monitor(1, 1, 0, Inf), ...
    'ffe_freeze_monitor:InvalidStartBlock');
assertThrowsId(@() ffe_freeze_monitor(1, 1, 0), ...
    'ffe_freeze_monitor:InvalidConstructor');

monitor = ffe_freeze_monitor(3, 2, 1, 1);
assertThrowsId(@() monitor.update(NaN, 1), ...
    'ffe_freeze_monitor:InvalidCode');
assertThrowsId(@() monitor.update(0.5, 1), ...
    'ffe_freeze_monitor:InvalidCode');
assertThrowsId(@() monitor.update(0, 0), ...
    'ffe_freeze_monitor:InvalidBlock');
assert(~monitor.update(-128, 1));           % negative integer codes are valid
assertThrowsId(@() monitor.update(-128, 1), ...
    'ffe_freeze_monitor:NonMonotonicBlock');
assertThrowsId(@() monitor.update(-128, 0.5), ...
    'ffe_freeze_monitor:InvalidBlock');
assert(monitor.LastBlock == 1);             % rejected calls do not mutate state
end

function triggers = feed(monitor, codes, firstBlock)
triggers = false(size(codes));
for index = 1:numel(codes)
    triggers(index) = monitor.update(codes(index), firstBlock + index - 1);
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
