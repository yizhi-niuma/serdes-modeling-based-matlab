function test_cdr_ffe_loop
% test_cdr_ffe_loop  Automated regression checks for CDR FFE block LMS.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

testFormulaSignAndBlockNormalization();
testValidatedRowAndColumnError();
testFastPathEquivalenceAndStateIsolation();
testAdaptationMaskAndMainTap();
testStepSizeAndReset();
testInvalidUpdateInput();
testInvalidConfiguration();
testCdrFfeIntegration();

fprintf('test_cdr_ffe_loop passed 8 / 8 checks.\n');
end

function testFormulaSignAndBlockNormalization()
lms = cdr_ffe_loop(0.2, 3, 2, 4, logical([1 0 1]));
dataRegressor = [1 2 3; 4 5 6; 7 8 9; 10 11 12];
errorBlock = [1 -2 3 -4];
expectedGradient = errorBlock * dataRegressor / 4;
expectedDelta = 0.2 * expectedGradient;
expectedDelta(2) = 0;

deltaCoefficients = lms.update(dataRegressor, errorBlock);
state = lms.getState();

assert(max(abs(deltaCoefficients - expectedDelta)) < 1e-12);
assert(max(abs(state.LastGradient - expectedGradient)) < 1e-12);
assert(state.UpdateCount == 1);

doubledLms = cdr_ffe_loop(0.2, 3, 2, 8, logical([1 0 1]));
doubledDelta = doubledLms.update([dataRegressor; dataRegressor], [errorBlock errorBlock]);
assert(max(abs(doubledDelta - expectedDelta)) < 1e-12);
end

function testValidatedRowAndColumnError()
dataRegressor = single(reshape(1:24, 4, 6));
errorRow = single([0.5 -1 1.5 -2]);
rowLms = cdr_ffe_loop(0.125, 6, 3, 4);
columnLms = cdr_ffe_loop(0.125, 6, 3, 4);

rowDelta = rowLms.update(dataRegressor, errorRow);
columnDelta = columnLms.update(dataRegressor, errorRow.');

assert(isequal(rowDelta, columnDelta));
assert(isa(rowDelta, 'double'));
assert(isequal(rowLms.getState(), columnLms.getState()));
end

function testFastPathEquivalenceAndStateIsolation()
dataRegressor = reshape(double(1:24), 4, 6);
errorVector = [1 -1 2 -2];
validatedLms = cdr_ffe_loop(0.05, 6, 3, 4);
fastLms = cdr_ffe_loop(0.05, 6, 3, 4);
singleOutputLms = cdr_ffe_loop(0.05, 6, 3, 4);

validatedDelta = validatedLms.update(dataRegressor, errorVector);
[fastDelta, fastGradient] = fastLms.updateFast(dataRegressor, errorVector);
singleOutputDelta = singleOutputLms.updateFast(dataRegressor, errorVector);
validatedState = validatedLms.getState();
fastState = fastLms.getState();
singleOutputState = singleOutputLms.getState();
expectedGradient = errorVector * dataRegressor / 4;
expectedDelta = 0.05 * expectedGradient;
expectedDelta(3) = 0;

assert(isequal(validatedDelta, fastDelta));
assert(isequal(fastDelta, expectedDelta));
assert(isequal(fastGradient, expectedGradient));
assert(isequal(singleOutputDelta, fastDelta));
assert(validatedState.UpdateCount == 1);
assert(isequal(validatedState.LastGradient, fastGradient));
assert(isequal(validatedState.LastDelta, validatedDelta));
assert(fastState.UpdateCount == 0);
assert(isequal(fastState.LastGradient, zeros(1, 6)));
assert(isequal(fastState.LastDelta, zeros(1, 6)));
assert(isequal(singleOutputState, fastState));
end

function testAdaptationMaskAndMainTap()
adaptEnableMask = logical([1 0 0 1 0 1]);
lms = cdr_ffe_loop(0.5, 6, 3, 2, adaptEnableMask);
dataRegressor = ones(2, 6);
deltaCoefficients = lms.update(dataRegressor, [1 1]);
state = lms.getState();

assert(isequal(state.LastGradient, ones(1, 6)));
assert(isequal(deltaCoefficients, [0.5 0 0 0.5 0 0.5]));
assert(deltaCoefficients(3) == 0);
end

function testStepSizeAndReset()
lms = cdr_ffe_loop(0.1, 3, 2, 2, logical([1 0 1]));
dataRegressor = [1 2 3; 4 5 6];
errorVector = [1 -1];
lms.update(dataRegressor, errorVector);
lms.setStepSize(0.25);
deltaCoefficients = lms.update(dataRegressor, errorVector);
expectedGradient = errorVector * dataRegressor / 2;
expectedDelta = 0.25 * expectedGradient;
expectedDelta(2) = 0;

assert(max(abs(deltaCoefficients - expectedDelta)) < 1e-12);
assert(lms.getState().UpdateCount == 2);
lms.resetState();
state = lms.getState();
assert(state.StepSize == 0.25);
assert(state.UpdateCount == 0);
assert(isequal(state.LastGradient, zeros(1, 3)));
assert(isequal(state.LastDelta, zeros(1, 3)));
end

function testInvalidUpdateInput()
lms = cdr_ffe_loop(0.1, 3, 2, 4, logical([1 0 1]));
validRegressor = ones(4, 3);
assertThrowsId(@() lms.update(ones(3, 4), ones(1, 4)), 'cdr_ffe_loop:InvalidRegressor');
assertThrowsId(@() lms.update([validRegressor(1:3, :); NaN NaN NaN], ones(1, 4)), 'cdr_ffe_loop:InvalidRegressor');
assertThrowsId(@() lms.update(validRegressor, ones(2, 2)), 'cdr_ffe_loop:InvalidErrorBlock');
assertThrowsId(@() lms.update(validRegressor, [1 2 3 Inf]), 'cdr_ffe_loop:InvalidErrorBlock');
end

function testInvalidConfiguration()
assertThrowsId(@() cdr_ffe_loop(), 'cdr_ffe_loop:MissingStepSize');
assertThrowsId(@() cdr_ffe_loop(-0.1), 'cdr_ffe_loop:InvalidStepSize');
assertThrowsId(@() cdr_ffe_loop(0.1, 0), 'cdr_ffe_loop:InvalidConfiguration');
assertThrowsId(@() cdr_ffe_loop(0.1, 6, 7), 'cdr_ffe_loop:InvalidMainTapIndex');
assertThrowsId(@() cdr_ffe_loop(0.1, 6, 3, 64, true(1, 6)), 'cdr_ffe_loop:MainTapAdaptEnabled');
assertThrowsId(@() cdr_ffe_loop(0.1, 6, 3, 64, logical([1 1 0 1 1])), 'cdr_ffe_loop:InvalidAdaptEnableMask');
lms = cdr_ffe_loop(0.1);
assertThrowsId(@() lms.setStepSize(NaN), 'cdr_ffe_loop:InvalidStepSize');
end

function testCdrFfeIntegration()
ffe = cdr_ffe();
lms = cdr_ffe_loop(0.01, ffe.TapCount, ffe.MainTapIndex, 8);
inputWindow = double(1:13);
[outputBlock, dataRegressor] = ffe.processBlockFast(inputWindow);
desiredBlock = outputBlock + [1 -1 1 -1 1 -1 1 -1];
errorVector = desiredBlock - outputBlock;
deltaCoefficients = lms.updateFast(dataRegressor, errorVector);
expectedDelta = 0.01 * (errorVector * dataRegressor / 8);
expectedDelta(ffe.MainTapIndex) = 0;

assert(max(abs(deltaCoefficients - expectedDelta)) < 1e-12);
ffe.applyCoefficientDelta(deltaCoefficients);
assert(ffe.Coefficients(ffe.MainTapIndex) == 1);
assert(max(abs(ffe.Coefficients - ([0 0 1 0 0 0] + expectedDelta))) < 1e-12);
end

function assertThrowsId(testFcn, expectedId)
didThrow = false;
try
    testFcn();
catch err
    didThrow = true;
    assert(strcmp(err.identifier, expectedId), 'Expected error %s, received %s.', expectedId, err.identifier);
end
assert(didThrow, 'Expected error %s was not thrown.', expectedId);
end
