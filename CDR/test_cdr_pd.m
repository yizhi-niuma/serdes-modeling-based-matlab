clear;
clc;

thisFile = mfilename('fullpath');
if isempty(thisFile)
    thisDir = 'C:\Work\MatLab_Lib\CDR';
else
    thisDir = fileparts(thisFile);
end

addpath(thisDir);

resultDir = fullfile(thisDir, 'result');
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

resultTxt = fullfile(resultDir, 'test_cdr_pd_result.txt');
wavePng = fullfile(resultDir, 'test_cdr_pd_waveform.png');

if exist(resultTxt, 'file')
    delete(resultTxt);
end

diary(resultTxt);
diary on;
cleanupObj = onCleanup(@() diary('off'));

testNames = {};
testStatus = {};
testMessage = {};
waveformResult = struct();

fprintf('test_cdr_pd started: %s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS'));
fprintf('Test script: %s\n', thisFile);
fprintf('Result folder: %s\n\n', resultDir);

[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'truth table', @testTruthTable);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'polarity', @testPolarity);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'threshold', @testThreshold);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'output and state', @testOutputAndState);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'matrix input', @testMatrixInput);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'invalid input', @testInvalidInput);
[testNames, testStatus, testMessage, waveformResult] = runWaveformTest(testNames, testStatus, testMessage, wavePng);

fprintf('\nSummary:\n');
for idx = 1:numel(testNames)
    fprintf('  %-22s : %s\n', testNames{idx}, testStatus{idx});
end

numPassed = sum(strcmp(testStatus, 'PASS'));
numTotal = numel(testStatus);
fprintf('\nPassed %d / %d tests.\n', numPassed, numTotal);
fprintf('Text result : %s\n', resultTxt);
fprintf('Waveform PNG: %s\n', wavePng);


if numPassed ~= numTotal
    error('test_cdr_pd failed: %d / %d tests passed.', numPassed, numTotal);
end

fprintf('\ntest_cdr_pd all tests passed.\n');

function [testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, name, testFcn)
    testNames{end + 1} = name;
    try
        testFcn();
        testStatus{end + 1} = 'PASS';
        testMessage{end + 1} = '';
        fprintf('[PASS] %s\n', name);
    catch err
        testStatus{end + 1} = 'FAIL';
        testMessage{end + 1} = err.message;
        fprintf('[FAIL] %s: %s\n', name, err.message);
    end
end

function [testNames, testStatus, testMessage, waveformResult] = runWaveformTest(testNames, testStatus, testMessage, wavePng)
    name = 'waveform function';
    testNames{end + 1} = name;
    try
        waveformResult = testWaveformFunction(wavePng);
        testStatus{end + 1} = 'PASS';
        testMessage{end + 1} = '';
        fprintf('[PASS] %s\n', name);
        fprintf('       waveform transitions: %d, valid decisions: %d\n', waveformResult.NumTransitions, waveformResult.NumValid);
        fprintf('       pdError sequence: %s\n', mat2str(waveformResult.PdError));
    catch err
        waveformResult = struct();
        testStatus{end + 1} = 'FAIL';
        testMessage{end + 1} = err.message;
        fprintf('[FAIL] %s: %s\n', name, err.message);
    end
end

function testTruthTable()
    pd = cdr_pd(0, 1);
    dataPrev = [-1 -1 -1 -1 1 1 1 1];
    edgeCurr = [-1 -1 1 1 -1 -1 1 1];
    dataCurr = [-1 1 -1 1 -1 1 -1 1];
    [pdError, valid, output] = pd.detect(dataPrev, edgeCurr, dataCurr);
    expectedValid = [false true false true true false true false];
    expectedRaw = [0 1 0 -1 -1 0 1 0];
    assertEqual(valid, expectedValid, 'truth table valid mismatch');
    assertEqual(output.RawDecision, expectedRaw, 'truth table raw decision mismatch');
    assertEqual(pdError, expectedRaw, 'truth table pdError mismatch');
end

function testPolarity()
    pd = cdr_pd(0, 1);
    [errPos, validPos] = pd.detect([-1 1 -1], [-1 -1 1], [1 -1 -1]);
    pdInv = cdr_pd(0, -1);
    [errNeg, validNeg] = pdInv.detect([-1 1 -1], [-1 -1 1], [1 -1 -1]);
    assertEqual(validPos, [true true false], 'positive polarity valid mismatch');
    assertEqual(validNeg, [true true false], 'negative polarity valid mismatch');
    assertEqual(errPos, [1 -1 0], 'positive polarity pdError mismatch');
    assertEqual(errNeg, [-1 1 0], 'negative pdError mismatch');
end

function testThreshold()
    pd = cdr_pd(0.2, 1);
    [err, valid, output] = pd.detect([0.2 -0.1 0.3], [0.1 -0.2 0.1], [0.3 0.5 0.3]);
    assertEqual(output.DataDecisionPrev, [false false true], 'threshold dPrev mismatch');
    assertEqual(output.EdgeDecisionCurr, [false false false], 'threshold eCurr mismatch');
    assertEqual(output.DataDecisionCurr, [true true true], 'threshold dCurr mismatch');
    assertEqual(valid, [true true false], 'threshold valid mismatch');
    assertEqual(err, [1 1 0], 'threshold pdError mismatch');
end

function testOutputAndState()
    pd = cdr_pd(0, 1);
    [err, valid, output] = pd.detect([-1 1], [-1 -1], [1 -1]);
    state = pd.getState();
    requiredFields = {'PdType', 'Threshold', 'Polarity', 'DataDecisionPrev', 'EdgeDecisionCurr', 'DataDecisionCurr', 'Transition', 'RawDecision', 'Valid', 'PdError'};
    for idx = 1:numel(requiredFields)
        assert(isfield(output, requiredFields{idx}), ['output missing field: ', requiredFields{idx}]);
    end
    assert(~isfield(output, 'BbpdType'), 'output should not contain BbpdType');
    assert(~isfield(state, 'BbpdType'), 'state should not contain BbpdType');
    assertEqual(state.LastOutput.PdError, err, 'state LastOutput PdError mismatch');
    assertEqual(state.LastOutput.Valid, valid, 'state LastOutput Valid mismatch');
end

function testMatrixInput()
    pd = cdr_pd(0, 1);
    dataPrev = [-1 1; -1 1];
    edgeCurr = [-1 -1; 1 1];
    dataCurr = [1 -1; 1 1];
    [err, valid, output] = pd.detect(dataPrev, edgeCurr, dataCurr);
    assertEqual(size(err), [2 2], 'matrix pdError size mismatch');
    assertEqual(valid, [true true; true false], 'matrix valid mismatch');
    assertEqual(output.RawDecision, [1 -1; -1 0], 'matrix raw decision mismatch');
end

function testInvalidInput()
    pd = cdr_pd(0, 1);
    assertThrows(@() cdr_pd(0, 0), 'invalid polarity should throw');
    assertThrows(@() cdr_pd(NaN, 1), 'invalid threshold should throw');
    assertThrows(@() pd.detect([1 2], [1 2 3], [1 2]), 'size mismatch should throw');
    assertThrows(@() pd.detect([1 NaN], [1 2], [1 2]), 'NaN input should throw');
end

function waveformResult = testWaveformFunction(wavePng)
    samplesPerUI = 64;
    bits = [0 1 0 1 1 0 0 1 0 1 1 0];
    levels = 2 * bits - 1;
    transitionOffsetUI = [0.18 -0.18 0.16 0 -0.16 0 0.20 -0.20 0.14 0 -0.14];
    riseSigmaUI = 0.025;

    t = 0:1 / samplesPerUI:(numel(levels) - 1 / samplesPerUI);
    waveform = levels(1) * ones(size(t));
    for idx = 2:numel(levels)
        if levels(idx) ~= levels(idx - 1)
            transitionTime = idx - 1 + transitionOffsetUI(idx - 1);
            step = 0.5 * (1 + tanh((t - transitionTime) / riseSigmaUI));
            waveform = waveform + (levels(idx) - levels(idx - 1)) * step;
        end
    end

    dataTime = 0.5:1:(numel(levels) - 0.5);
    edgeTime = 1:1:(numel(levels) - 1);
    dataSample = interp1(t, waveform, dataTime, 'linear');
    edgeSample = interp1(t, waveform, edgeTime, 'linear');

    dataSamplePrev = dataSample(1:end - 1);
    dataSampleCurr = dataSample(2:end);

    pd = cdr_pd(0, 1);
    [pdError, valid, output] = pd.detect(dataSamplePrev, edgeSample, dataSampleCurr);

    expectedRaw = zeros(size(pdError));
    expectedRaw(output.Transition) = -1;
    expectedRaw(output.Transition & (output.EdgeDecisionCurr == output.DataDecisionPrev)) = 1;

    assertEqual(output.RawDecision, expectedRaw, 'waveform raw decision mismatch');
    assertEqual(pdError, expectedRaw, 'waveform pdError mismatch');
    assert(any(pdError == 1), 'waveform test should contain early decisions');
    assert(any(pdError == -1), 'waveform test should contain late decisions');
    assert(any(~valid), 'waveform test should contain invalid UIs');

    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 650]);
    subplot(2, 1, 1);
    plot(t, waveform, 'b-', 'LineWidth', 1.2);
    hold on;
    yline(0, 'k--');
    plot(dataTime, dataSample, 'ko', 'MarkerFaceColor', 'g', 'DisplayName', 'data sample');
    plot(edgeTime, edgeSample, 'rs', 'MarkerFaceColor', 'r', 'DisplayName', 'edge sample');
    grid on;
    xlabel('UI');
    ylabel('sample value');
    title('test cdr pd waveform samples');
    legend('waveform', 'threshold', 'data sample', 'edge sample', 'Location', 'best');

    subplot(2, 1, 2);
    stem(edgeTime, pdError, 'filled', 'LineWidth', 1.2);
    hold on;
    plot(edgeTime(valid), pdError(valid), 'go', 'MarkerSize', 8, 'LineWidth', 1.2);
    plot(edgeTime(~valid), pdError(~valid), 'kx', 'MarkerSize', 8, 'LineWidth', 1.2);
    grid on;
    ylim([-1.5 1.5]);
    yticks([-1 0 1]);
    xlabel('UI boundary');
    ylabel('pdError');
    title('BBPD decision: +1 early, -1 late, 0 invalid');
    legend('pdError', 'valid', 'invalid', 'Location', 'best');

    saveas(fig, wavePng);
    close(fig);

    waveformResult = struct();
    waveformResult.Bits = bits;
    waveformResult.TransitionOffsetUI = transitionOffsetUI;
    waveformResult.DataSample = dataSample;
    waveformResult.EdgeSample = edgeSample;
    waveformResult.PdError = pdError;
    waveformResult.Valid = valid;
    waveformResult.RawDecision = output.RawDecision;
    waveformResult.NumTransitions = sum(output.Transition);
    waveformResult.NumValid = sum(valid);
end

function assertThrows(fh, message)
    didThrow = false;
    try
        fh();
    catch
        didThrow = true;
    end
    assert(didThrow, message);
end

function assertEqual(actual, expected, message)
    assert(isequaln(actual, expected), message);
end
