function test_cdr_loop
% test_cdr_loop  Automated regression checks for cdr_loop.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

testPiUpdateOrder();
testPositiveResidueQuantization();
testNegativeResidueQuantization();
testFrequencySaturationAndRecovery();
testModeIndependentNumericInput();
testFastPathEquivalence();
testPiInterfaceCompatibility();
testRuntimeConfigurationAndReset();
testDeltaCodeLimit();
testInvalidInputAndConfiguration();

fprintf('test_cdr_loop passed 10 / 10 checks.\n');
end

function testPiUpdateOrder()
loop = cdr_loop(0.2, 0.05, -Inf, Inf, Inf);
deltaCode = loop.update(10);
state = loop.getState();

assert(deltaCode == 2);
assert(abs(state.FrequencyState - 0.5) < 1e-12);
assert(abs(state.LastControl - 2.5) < 1e-12);
assert(abs(state.CodeResidue - 0.5) < 1e-12);
end

function testPositiveResidueQuantization()
loop = cdr_loop(0.3, 0);
deltaCode = zeros(1, 10);
for k = 1:numel(deltaCode)
    deltaCode(k) = loop.update(1);
end

assert(all(deltaCode == [0 0 0 1 0 0 1 0 0 0]));
assert(abs(sum(deltaCode) + loop.CodeResidue - 3) < 1e-12);
end

function testNegativeResidueQuantization()
loop = cdr_loop(0.3, 0);
deltaCode = zeros(1, 10);
for k = 1:numel(deltaCode)
    deltaCode(k) = loop.update(-1);
end

assert(all(deltaCode == [0 0 0 -1 0 0 -1 0 0 0]));
assert(abs(sum(deltaCode) + loop.CodeResidue + 3) < 1e-12);
end

function testFrequencySaturationAndRecovery()
loop = cdr_loop(0, 0.5, -1, 1);

loop.update(4);
assert(loop.FrequencyState == 1);
loop.update(4);
assert(loop.FrequencyState == 1);
loop.update(-1);
assert(loop.FrequencyState == 0.5);
loop.update(-4);
assert(loop.FrequencyState == -1);
end

function testModeIndependentNumericInput()
loopLinear = cdr_loop(0.25, 0, -Inf, Inf, Inf);
loopConstant = cdr_loop(0.25, 0, -Inf, Inf, Inf);

assert(loopLinear.update(int16(12)) == 3);
assert(loopConstant.update(int16(8)) == 2);
end

function testFastPathEquivalence()
phaseError = [12 4 -8 0 5 -3];
loopDebug = cdr_loop(0.2, 0.03, -2, 2);
loopFast = cdr_loop(0.2, 0.03, -2, 2);

for k = 1:numel(phaseError)
    assert(loopDebug.update(phaseError(k)) == ...
        loopFast.updateFast(phaseError(k)));
end

assert(isequal(loopDebug.getState(), loopFast.getState()));
end

function testPiInterfaceCompatibility()
loop = cdr_loop(0.25, 0, -Inf, Inf, Inf);
piModel = cdr_pi(8, 128);

deltaCode = loop.update(8);
piModel.update(deltaCode);

assert(deltaCode == fix(deltaCode));
assert(piModel.CodeWrapped == 2);
end

function testRuntimeConfigurationAndReset()
loop = cdr_loop(0.2, 0.1);
loop.update(10);
loop.setGains(0.4, 0.2);
loop.setFrequencyLimits(-0.5, 0.5);

assert(loop.Kp == 0.4);
assert(loop.Ki == 0.2);
assert(loop.FrequencyState == 0.5);

loop.resetState();
assert(loop.FrequencyState == 0);
assert(loop.CodeResidue == 0);
assert(loop.PendingCode == 0);
assert(loop.LastControl == 0);
assert(loop.LastRawDeltaCode == 0);
assert(loop.LastDeltaCode == 0);
end

function testDeltaCodeLimit()
loop = cdr_loop(0.25, 0);

assert(loop.update(8) == 1);
assert(loop.MaxDeltaCode == 1);
assert(loop.LastRawDeltaCode == 2);
assert(loop.LastDeltaCode == 1);
assert(loop.CodeResidue == 0);
assert(loop.PendingCode == 1);

assert(loop.update(8) == 1);
assert(loop.LastRawDeltaCode == 2);
assert(loop.PendingCode == 2);

% Reverse demand first cancels queued forward code, then applies the rest.
assert(loop.update(-12) == -1);
assert(loop.LastRawDeltaCode == -3);
assert(loop.LastDeltaCode == -1);
assert(loop.PendingCode == 0);

loop.setMaxDeltaCode(2);
assert(loop.update(12) == 2);
assert(loop.LastRawDeltaCode == 3);
assert(loop.LastDeltaCode == 2);
assert(loop.PendingCode == 1);

loop.setMaxDeltaCode(Inf);
assert(loop.update(-12) == -2);
assert(loop.PendingCode == 0);
end

function testInvalidInputAndConfiguration()
assertThrowsId(@() cdr_loop(), 'cdr_loop:MissingGain');
assertThrowsId(@() cdr_loop(-1, 0.1), 'cdr_loop:InvalidGain');
assertThrowsId(@() cdr_loop(0.1, Inf), 'cdr_loop:InvalidGain');
assertThrowsId(@() cdr_loop(0.1, 0.01, 1, -1), ...
    'cdr_loop:InvalidFrequencyLimits');
assertThrowsId(@() cdr_loop(0.1, 0.01, Inf, Inf), ...
    'cdr_loop:InvalidFrequencyLimits');
assertThrowsId(@() cdr_loop(0.1, 0.01, -Inf, Inf, 0), ...
    'cdr_loop:InvalidMaxDeltaCode');
assertThrowsId(@() cdr_loop(0.1, 0.01, -Inf, Inf, 1.5), ...
    'cdr_loop:InvalidMaxDeltaCode');

loop = cdr_loop(0.1, 0.01);
assertThrowsId(@() loop.update([1 2]), 'cdr_loop:InvalidPhaseError');
assertThrowsId(@() loop.update(NaN), 'cdr_loop:InvalidPhaseError');
assertThrowsId(@() loop.setFrequencyLimits(NaN, 1), ...
    'cdr_loop:InvalidFrequencyLimits');
assertThrowsId(@() loop.setMaxDeltaCode(-1), ...
    'cdr_loop:InvalidMaxDeltaCode');
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
