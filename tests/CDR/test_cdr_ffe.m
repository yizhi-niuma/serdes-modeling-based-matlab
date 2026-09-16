function test_cdr_ffe
% test_cdr_ffe  Automated regression checks for window-based CDR FFE.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
addpath(fullfile(repoRoot, 'src', 'CDR'));

testDefaultWindowMapping();
testConfiguredFirMapping();
testRowVectorContract();
testFastPathEquivalence();
testCoefficientUpdateAndReset();
testInvalidInput();
testInvalidConfiguration();

fprintf('test_cdr_ffe passed 7 / 7 checks.\n');
end

function testDefaultWindowMapping()
ffe = cdr_ffe();
inputWindow = 1:13;
[outputBlock, regressor] = ffe.processBlock(inputWindow);

assert(isequal(outputBlock, 4:11));
assert(isequal(size(regressor), [8 6]));
assert(isequal(regressor(1, :), [6 5 4 3 2 1]));
assert(isequal(regressor(end, :), [13 12 11 10 9 8]));
assert(isrow(outputBlock));
end

function testConfiguredFirMapping()
coefficients = [0.25 -0.5 1 0.75 -0.25 0.125];
ffe = cdr_ffe(coefficients, 2);
inputWindow = [-3 -2 -1 10 20 30 40 50 60 70 80];
[outputBlock, regressor] = ffe.processBlock(inputWindow);
expectedOutput = regressor * coefficients.';

assert(max(abs(outputBlock(:) - expectedOutput)) < 1e-12);
assert(numel(outputBlock) == 6);
end

function testRowVectorContract()
ffe = cdr_ffe();
[outputBlock, regressor] = ffe.processBlock(single(1:13));

assert(isrow(outputBlock));
assert(isa(outputBlock, 'double'));
assert(isa(regressor, 'double'));
assertThrowsId(@() ffe.processBlock((1:13).'), 'cdr_ffe:InvalidInputWindow');
end

function testFastPathEquivalence()
coefficients = [0.1 -0.2 1 0.3 -0.1 0.05];
inputWindow = linspace(-1, 1, 21);
ffeValidated = cdr_ffe(coefficients, 2);
ffeFast = cdr_ffe(coefficients, 2);
[validatedOutput, validatedRegressor] = ffeValidated.processBlock(inputWindow);
[fastOutput, fastRegressor] = ffeFast.processBlockFast(inputWindow);

assert(isequal(validatedOutput, fastOutput));
assert(isequal(validatedRegressor, fastRegressor));
assert(isequal(ffeValidated.getState(), ffeFast.getState()));
end

function testCoefficientUpdateAndReset()
ffe = cdr_ffe();
delta = [0.1 -0.2 0 0.3 -0.1 0.05];
ffe.applyCoefficientDelta(delta);
assert(isequal(ffe.Coefficients, [0.1 -0.2 1 0.3 -0.1 0.05]));
ffe.processBlock(1:13);
ffe.resetState();
assert(isequal(ffe.Coefficients, [0 0 1 0 0 0]));
assertThrowsId(@() ffe.applyCoefficientDelta([0 0 1 0 0 0]), 'cdr_ffe:MainTapUpdate');
end

function testInvalidInput()
ffe = cdr_ffe();
assertThrowsId(@() ffe.processBlock([]), 'cdr_ffe:InvalidInputWindow');
assertThrowsId(@() ffe.processBlock([1 2 NaN 4 5 6]), 'cdr_ffe:InvalidInputWindow');
assertThrowsId(@() ffe.processBlock([1 2; 3 4]), 'cdr_ffe:InvalidInputWindow');
assertThrowsId(@() ffe.processBlock(1:5), 'cdr_ffe:InputWindowTooShort');
end

function testInvalidConfiguration()
assertThrowsId(@() cdr_ffe([0 1 0], 0), 'cdr_ffe:InvalidMainTap');
assertThrowsId(@() cdr_ffe([0 1 0], 3), 'cdr_ffe:InvalidPreTapCount');
assertThrowsId(@() cdr_ffe([0 NaN 1], 2), 'cdr_ffe:InvalidCoefficients');
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
