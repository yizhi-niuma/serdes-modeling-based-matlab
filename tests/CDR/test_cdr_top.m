function test_cdr_top
% test_cdr_top  Automated regression checks for cdr_top.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

testComponentScheduling();
testCrossBlockOverlap();
testColumnBlock();
testReset();
testFastPathEquivalence();
testInvalidInputAndConfiguration();

fprintf('test_cdr_top passed 6 / 6 checks.\n');
end

function testComponentScheduling()
top = buildTop('pam4', 4, 0.25, 0, 0);
top.PhaseInterpolator.resetNonideal();

dataCurrBlock = [3 0 3 0];
edgeBitBlock = [0 1 0 1];
output = top.processBlock(dataCurrBlock, edgeBitBlock);

assert(all(output.DataPrevBlock == [0 3 0 3]));
assert(all(output.PhaseDecision == [1 1 1 1]));
assert(all(output.Valid));
assert(output.PhaseError == 4);
assert(output.DeltaCode == 1);
assert(output.SampleIndexForBlock == 0);
assert(abs(output.NextLocalIndexFloat - 0.5) < 1e-12);
assert(output.PiCodeWrapped == 1);
assert(output.PiUiSlip == 0);
assert(top.BlockIndex == 1);
end

function testCrossBlockOverlap()
top = buildTop('pam4', 4, 0, 0, 2);

firstOutput = top.processBlock([1 2 1 2], [1 1 1 1]);
secondOutput = top.processBlock([1 2 1 2], [1 1 1 1]);

assert(firstOutput.PreviousSymbolIn == 2);
assert(all(firstOutput.DataPrevBlock == [2 1 2 1]));
assert(secondOutput.PreviousSymbolIn == 2);
assert(all(secondOutput.DataPrevBlock == [2 1 2 1]));
assert(top.PreviousSymbol == 2);
assert(top.BlockIndex == 2);
end

function testColumnBlock()
top = buildTop('nrz', 4, 0, 0, 1);
output = top.processBlock([0; 1; 1; 0], [1; 0; 1; 1]);

assert(iscolumn(output.DataPrevBlock));
assert(all(output.DataPrevBlock == [1; 0; 1; 1]));
assert(iscolumn(output.PhaseDecision));
end

function testReset()
top = buildTop('pam4', 4, 0.25, 0.1, 0);
top.processBlock([3 0 3 0], [0 1 0 1]);
top.resetState(1);
state = top.getState();

assert(state.BlockIndex == 0);
assert(state.PreviousSymbol == 1);
assert(state.CurrentLocalIndexFloat == 0);
assert(isempty(fieldnames(state.LastOutput)));
assert(state.LoopFilter.FrequencyState == 0);
assert(state.LoopFilter.CodeResidue == 0);
assert(state.PhaseInterpolator.CodeWrapped == 0);
assert(state.PhaseInterpolator.UiSlip == 0);
end

function testFastPathEquivalence()
topDebug = buildTop('pam4', 4, 0.2, 0.03, 0);
topFast = buildTop('pam4', 4, 0.2, 0.03, 0);
topDebug.PhaseInterpolator.resetNonideal();
topFast.PhaseInterpolator.resetNonideal();

dataBlocks = [3 0 3 0; 3 0 3 0; 1 2 1 2];
edgeBlocks = [0 1 0 1; 1 0 1 0; 1 0 1 0];
for blockIndex = 1:size(dataBlocks, 1)
    output = topDebug.processBlock( ...
        dataBlocks(blockIndex, :), edgeBlocks(blockIndex, :));
    [sampleIndexForBlock, nextLocalIndexFloat, phaseError, deltaCode] = ...
        topFast.processBlockFast( ...
        dataBlocks(blockIndex, :), edgeBlocks(blockIndex, :));

    assert(sampleIndexForBlock == output.SampleIndexForBlock);
    assert(nextLocalIndexFloat == output.NextLocalIndexFloat);
    assert(phaseError == output.PhaseError);
    assert(deltaCode == output.DeltaCode);
end

assert(topFast.PreviousSymbol == topDebug.PreviousSymbol);
assert(topFast.BlockIndex == topDebug.BlockIndex);
assert(topFast.CurrentLocalIndexFloat == topDebug.CurrentLocalIndexFloat);
assert(topFast.PhaseInterpolator.CodeWrapped == ...
    topDebug.PhaseInterpolator.CodeWrapped);
assert(topFast.PhaseInterpolator.UiSlip == topDebug.PhaseInterpolator.UiSlip);
assert(isequal(topFast.LoopFilter.getState(), ...
    topDebug.LoopFilter.getState()));
assert(isempty(fieldnames(topFast.LastOutput)));
end

function testInvalidInputAndConfiguration()
pd = cdr_pd('pam4', 1);
voter = cdr_voter('linear', 4, 8);
loopFilter = cdr_loop(0.2, 0.01);
piModel = cdr_pi(8, 128);

assertThrowsId(@() cdr_top(pd, voter, loopFilter, piModel), ...
    'cdr_top:MissingInput');
assertThrowsId(@() cdr_top(pd, voter, loopFilter, piModel, 4), ...
    'cdr_top:InvalidInitialSymbol');
assertThrowsId(@() cdr_top(pd, voter, loopFilter, loopFilter, 0), ...
    'cdr_top:InvalidComponent');

top = cdr_top(pd, voter, loopFilter, piModel, 0);
assertThrowsId(@() top.processBlock([0 1], [0 1]), ...
    'cdr_top:InvalidDataBlock');
assertThrowsId(@() top.processBlock([0 1 2 3], [0; 1; 0; 1]), ...
    'cdr_top:InvalidEdgeBlock');
assertThrowsId(@() top.processBlock([0 1 2 4], [0 1 0 1]), ...
    'cdr_pd:InvalidDigitalInput');
assertThrowsId(@() top.resetState(-1), ...
    'cdr_top:InvalidInitialSymbol');
end

function top = buildTop(mode, blockSize, Kp, Ki, initialSymbol)
pd = cdr_pd(mode, 1);
voter = cdr_voter('linear', blockSize, 8);
loopFilter = cdr_loop(Kp, Ki);
piModel = cdr_pi(8, 128);
top = cdr_top(pd, voter, loopFilter, piModel, initialSymbol);
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
