function test_cdr_voter
% test_cdr_voter  Automated regression checks for cdr_voter.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

testDefaultLinearMode();
testConstantMode();
testRowColumnEquivalence();
testFastPathEquivalence();
testModeUpdate();
testInvalidInput();
testInvalidConfiguration();

fprintf('test_cdr_voter passed 7 / 7 checks.\n');
end

function testDefaultLinearMode()
voter = cdr_voter();
phaseDecision = [ones(1, 20), -ones(1, 7), zeros(1, 37)];
phaseError = voter.vote(phaseDecision);

assert(isa(phaseError, 'int16'));
assert(phaseError == int16(13));
assert(strcmp(voter.Mode, 'linear'));
assert(voter.BlockSize == int16(64));
assert(voter.ConstantMagnitude == int16(8));
end

function testConstantMode()
voter = cdr_voter('constant', 8, 8);

assert(voter.vote([1 1 0 0 0 0 -1 0]) == int16(8));
assert(voter.vote([-1 -1 0 0 0 0 1 0]) == int16(-8));
assert(voter.vote([1 -1 0 0 0 0 0 0]) == int16(0));
end

function testRowColumnEquivalence()
voter = cdr_voter('linear', 8, 8);
phaseDecision = int8([1 1 1 0 -1 0 0 0]);

assert(voter.vote(phaseDecision) == int16(2));
assert(voter.vote(phaseDecision.') == int16(2));
end

function testFastPathEquivalence()
rng(13);
phaseDecision = int8(randi(3, 1, 64) - 2);

for mode = {'linear', 'constant'}
    voter = cdr_voter(mode{1});
    assert(voter.voteFast(phaseDecision) == voter.vote(phaseDecision));
end
end

function testModeUpdate()
voter = cdr_voter('linear', 4, 3);
phaseDecision = [1 1 1 -1];

assert(voter.vote(phaseDecision) == int16(2));
voter.setMode('constant');
assert(voter.vote(phaseDecision) == int16(3));
end

function testInvalidInput()
voter = cdr_voter('linear', 4, 8);

assertThrowsId(@() voter.vote([1 0 -1]), 'cdr_voter:InvalidPhaseDecision');
assertThrowsId(@() voter.vote([1 0; -1 0]), 'cdr_voter:InvalidPhaseDecision');
assertThrowsId(@() voter.vote([1 0 2 -1]), 'cdr_voter:InvalidPhaseDecision');
assertThrowsId(@() voter.vote([1 0 NaN -1]), 'cdr_voter:InvalidPhaseDecision');
end

function testInvalidConfiguration()
assertThrowsId(@() cdr_voter('invalid'), 'cdr_voter:InvalidMode');
assertThrowsId(@() cdr_voter('linear', 0), 'cdr_voter:InvalidConfiguration');
assertThrowsId(@() cdr_voter('linear', 32768), 'cdr_voter:InvalidConfiguration');
assertThrowsId(@() cdr_voter('linear', 64, 0), 'cdr_voter:InvalidConfiguration');
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
