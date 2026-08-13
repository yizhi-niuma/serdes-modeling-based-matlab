clear;
clc;

thisFile = mfilename('fullpath');
validationDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(validationDir));
sourceDir = fullfile(repoRoot, 'src', 'CDR');
addpath(sourceDir);

resultDir = fullfile(repoRoot, 'results', 'CDR');
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

[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'NRZ truth table', @testNrzTruthTable);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'PAM4 symmetric edges', @testPam4SymmetricEdges);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'polarity', @testPolarity);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'mode and state', @testModeAndState);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'matrix input', @testMatrixInput);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'fast path equivalence', @testFastPathEquivalence);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'explicit block overlap', @testExplicitBlockOverlap);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'invalid input', @testInvalidInput);
[testNames, testStatus, testMessage] = runOneTest(testNames, testStatus, testMessage, 'MMPD framework', @testMmpdFramework);
[testNames, testStatus, testMessage, waveformResult] = runWaveformTest(testNames, testStatus, testMessage, wavePng);

fprintf('\nSummary:\n');
for idx = 1:numel(testNames)
    fprintf('  %-24s : %s\n', testNames{idx}, testStatus{idx});
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
    name = 'external slicer waveform';
    testNames{end + 1} = name;
    try
        waveformResult = testWaveformFunction(wavePng);
        testStatus{end + 1} = 'PASS';
        testMessage{end + 1} = '';
        fprintf('[PASS] %s\n', name);
        fprintf('       waveform transitions: %d, valid decisions: %d\n', waveformResult.NumTransitions, waveformResult.NumValid);
        fprintf('       phaseDecision sequence: %s\n', mat2str(waveformResult.PhaseDecision));
    catch err
        waveformResult = struct();
        testStatus{end + 1} = 'FAIL';
        testMessage{end + 1} = err.message;
        fprintf('[FAIL] %s: %s\n', name, err.message);
    end
end

function testNrzTruthTable()
    pd = cdr_pd('nrz', 1);
    dataPrev = [0 0 0 0 1 1 1 1];
    edgeBit = [0 0 1 1 0 0 1 1];
    dataCurr = [0 1 0 1 0 1 0 1];
    [phaseDecision, valid, output] = pd.bbpd(dataPrev, edgeBit, dataCurr);
    expectedValid = [false true false true true false true false];
    expectedRaw = [0 1 0 -1 -1 0 1 0];
    assertEqual(valid, expectedValid, 'NRZ valid mismatch');
    assertEqual(output.RawDecision, expectedRaw, 'NRZ raw decision mismatch');
    assertEqual(phaseDecision, expectedRaw, 'NRZ phaseDecision mismatch');
end

function testPam4SymmetricEdges()
    pd = cdr_pd('pam4', 1);
    [dataPrev, dataCurr, edgeBit] = ndgrid(0:3, 0:3, 0:1);
    [phaseDecision, valid, output] = pd.bbpd(dataPrev, edgeBit, dataCurr);

    d0Msb = bitget(dataPrev, 2) ~= 0;
    d0Lsb = bitget(dataPrev, 1) ~= 0;
    d1Msb = bitget(dataCurr, 2) ~= 0;
    d1Lsb = bitget(dataCurr, 1) ~= 0;
    edge = edgeBit ~= 0;

    % Golden equations are a direct behavioral transcription of
    % cdr_bb_logic_lzy.sv early_n and late_n.
    expectedEarly = ...
        (d0Msb & ~d0Lsb & ~d1Msb & d1Lsb & edge) | ...
        (~d0Msb & d0Lsb & d1Msb & ~d1Lsb & ~edge) | ...
        (d0Msb & d0Lsb & ~d1Msb & ~d1Lsb & edge) | ...
        (~d0Msb & ~d0Lsb & d1Msb & d1Lsb & ~edge);
    expectedLate = ...
        (d0Msb & ~d0Lsb & ~d1Msb & d1Lsb & ~edge) | ...
        (~d0Msb & d0Lsb & d1Msb & ~d1Lsb & edge) | ...
        (d0Msb & d0Lsb & ~d1Msb & ~d1Lsb & ~edge) | ...
        (~d0Msb & ~d0Lsb & d1Msb & d1Lsb & edge);
    expectedValid = expectedEarly | expectedLate;
    expectedRaw = double(expectedEarly) - double(expectedLate);

    assertEqual(valid, expectedValid, 'PAM4 complete transition selection mismatch');
    assertEqual(output.Early, expectedEarly, 'PAM4 early truth table mismatch');
    assertEqual(output.Late, expectedLate, 'PAM4 late truth table mismatch');
    assertEqual(phaseDecision, expectedRaw, 'PAM4 phaseDecision mismatch');
end

function testPolarity()
    pdPos = cdr_pd('pam4', 1);
    pdNeg = cdr_pd('pam4', -1);
    [errPos, validPos] = pdPos.bbpd([2 1 0], [1 1 0], [1 2 1]);
    [errNeg, validNeg] = pdNeg.bbpd([2 1 0], [1 1 0], [1 2 1]);
    assertEqual(validPos, [true true false], 'positive polarity valid mismatch');
    assertEqual(validNeg, [true true false], 'negative polarity valid mismatch');
    assertEqual(errPos, [1 -1 0], 'positive polarity phaseDecision mismatch');
    assertEqual(errNeg, [-1 1 0], 'negative polarity phaseDecision mismatch');
end

function testModeAndState()
    pd = cdr_pd();
    assertEqual(pd.Mode, 'pam4', 'default mode mismatch');
    [err, valid, output] = pd.bbpd([3 1], [1 0], [0 2]);
    state = pd.getState();
    requiredFields = {'PdType', 'Mode', 'Polarity', 'DataSymbolPrev', 'EdgeBit', ...
        'DataSymbolCurr', 'DataSidePrev', 'Transition', 'Early', 'Late', ...
        'RawDecision', 'Valid', 'PhaseDecision'};
    for idx = 1:numel(requiredFields)
        assert(isfield(output, requiredFields{idx}), ['output missing field: ', requiredFields{idx}]);
    end
    assertEqual(output.PdType, 'bbpd', 'PD type mismatch');
    assertEqual(state.Mode, 'pam4', 'state mode mismatch');
    assertEqual(state.LastOutput.PhaseDecision, err, 'state LastOutput PhaseDecision mismatch');
    assertEqual(state.LastOutput.Valid, valid, 'state LastOutput Valid mismatch');

    pd.setMode('NRZ');
    assertEqual(pd.Mode, 'nrz', 'setMode should normalize case');
    assert(isempty(fieldnames(pd.LastOutput)), 'setMode should reset LastOutput');
end

function testMatrixInput()
    pd = cdr_pd('pam4', 1);
    dataPrev = [2 1; 3 0];
    edgeBit = [1 1; 0 0];
    dataCurr = [1 2; 0 1];
    [err, valid, output] = pd.bbpd(dataPrev, edgeBit, dataCurr);
    assertEqual(size(err), [2 2], 'matrix phaseDecision size mismatch');
    assertEqual(valid, [true true; true false], 'matrix valid mismatch');
    assertEqual(output.RawDecision, [1 -1; -1 0], 'matrix raw decision mismatch');
end

function testFastPathEquivalence()
    previousRng = rng;
    cleanupObj = onCleanup(@() rng(previousRng));
    rng(20260813, 'twister');

    modes = {'nrz', 'pam4'};
    polarities = [1 -1];
    blockShapes = {[1 64], [64 1], [8 8]};

    for modeIndex = 1:numel(modes)
        mode = modes{modeIndex};
        for polarity = polarities
            pd = cdr_pd(mode, polarity);
            for shapeIndex = 1:numel(blockShapes)
                blockShape = blockShapes{shapeIndex};
                if strcmp(mode, 'nrz')
                    dataPrev = randi([0 1], blockShape);
                    dataCurr = randi([0 1], blockShape);
                else
                    dataPrev = randi([0 3], blockShape);
                    dataCurr = randi([0 3], blockShape);
                end
                edgeBit = randi([0 1], blockShape);

                [expectedError, expectedValid] = pd.bbpd(dataPrev, edgeBit, dataCurr);
                stateBeforeFast = pd.getState();
                [fastError, fastValid] = pd.bbpdFast(dataPrev, edgeBit, dataCurr);
                stateAfterFast = pd.getState();

                assert(isa(fastError, 'int8'), 'fast-path phaseDecision must use int8 storage');
                assertEqual(fastError, int8(expectedError), ...
                    sprintf('%s fast-path phaseDecision mismatch', mode));
                assertEqual(fastValid, expectedValid, ...
                    sprintf('%s fast-path valid mismatch', mode));
                assertEqual(stateAfterFast, stateBeforeFast, ...
                    sprintf('%s fast path must not update state', mode));
            end
        end
    end
end

function testExplicitBlockOverlap()
    previousRng = rng;
    cleanupObj = onCleanup(@() rng(previousRng));
    rng(20260814, 'twister');

    modes = {'nrz', 'pam4'};
    polarities = [1 -1];
    blockLength = 64;
    numBlock = 5;

    for modeIndex = 1:numel(modes)
        mode = modes{modeIndex};
        if strcmp(mode, 'nrz')
            initialSymbol = randi([0 1]);
            dataCurr = randi([0 1], 1, blockLength * numBlock);
        else
            initialSymbol = randi([0 3]);
            dataCurr = randi([0 3], 1, blockLength * numBlock);
        end
        edgeBit = randi([0 1], size(dataCurr));
        dataPrev = [initialSymbol, dataCurr(1:end - 1)];

        for polarity = polarities
            referencePd = cdr_pd(mode, polarity);
            [expectedError, expectedValid] = referencePd.bbpdFast(dataPrev, edgeBit, dataCurr);

            blockPd = cdr_pd(mode, polarity);
            blockError = zeros(size(dataCurr), 'int8');
            blockValid = false(size(dataCurr));
            previousSymbol = initialSymbol;
            for blockIndex = 1:numBlock
                index = (blockIndex - 1) * blockLength + (1:blockLength);
                dataCurrBlock = dataCurr(index);
                dataPrevBlock = [previousSymbol, dataCurrBlock(1:end - 1)];
                [blockError(index), blockValid(index)] = blockPd.bbpdFast( ...
                    dataPrevBlock, edgeBit(index), dataCurrBlock);
                previousSymbol = dataCurrBlock(end);
            end

            assertEqual(blockError, expectedError, ...
                sprintf('%s block-boundary phaseDecision mismatch', mode));
            assertEqual(blockValid, expectedValid, ...
                sprintf('%s block-boundary valid mismatch', mode));

            state = blockPd.getState();
            assert(isempty(fieldnames(state.LastOutput)), ...
                sprintf('%s explicit block overlap must not update LastOutput', mode));
        end
    end
end

function testInvalidInput()
    pd = cdr_pd('pam4', 1);
    assertThrowsId(@() cdr_pd('invalid', 1), 'cdr_pd:InvalidMode', 'invalid mode should throw');
    assertThrowsId(@() cdr_pd('pam4', 0), 'cdr_pd:InvalidPolarity', 'invalid polarity should throw');
    assertThrowsId(@() pd.bbpd([1 2], [1 0 1], [2 1]), 'cdr_pd:SizeMismatch', 'size mismatch should throw');
    assertThrowsId(@() pd.bbpd([0 4], [0 1], [3 0]), 'cdr_pd:InvalidDigitalInput', 'invalid PAM4 symbol should throw');
    assertThrowsId(@() pd.bbpd([0 3], [0 2], [3 0]), 'cdr_pd:InvalidDigitalInput', 'invalid edge bit should throw');
    assertThrowsId(@() pd.bbpd([0 NaN], [0 1], [3 0]), 'cdr_pd:InvalidDigitalInput', 'NaN input should throw');
end

function testMmpdFramework()
    pd = cdr_pd('pam4', 1);
    assertThrowsId(@() pd.mmpd(3, 1, 0, 1), 'cdr_pd:MMPDNotImplemented', ...
        'MMPD framework should report not implemented');
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

    % Slicing belongs to the caller/front-end, not to the digital PD core.
    dataDecision = dataSample > 0;
    edgeDecision = edgeSample > 0;
    dataPrev = dataDecision(1:end - 1);
    dataCurr = dataDecision(2:end);

    pd = cdr_pd('nrz', 1);
    [phaseDecision, valid, output] = pd.bbpd(dataPrev, edgeDecision, dataCurr);

    expectedRaw = zeros(size(phaseDecision));
    expectedRaw(valid) = -1;
    expectedRaw(valid & (edgeDecision == dataPrev)) = 1;

    assertEqual(output.RawDecision, expectedRaw, 'waveform raw decision mismatch');
    assertEqual(phaseDecision, expectedRaw, 'waveform phaseDecision mismatch');
    assert(any(phaseDecision == 1), 'waveform test should contain early decisions');
    assert(any(phaseDecision == -1), 'waveform test should contain late decisions');
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
    title('External slicing before the digital NRZ BBPD');
    legend('waveform', 'slicer threshold', 'data sample', 'edge sample', 'Location', 'best');

    subplot(2, 1, 2);
    stem(edgeTime, phaseDecision, 'filled', 'LineWidth', 1.2);
    hold on;
    plot(edgeTime(valid), phaseDecision(valid), 'go', 'MarkerSize', 8, 'LineWidth', 1.2);
    plot(edgeTime(~valid), phaseDecision(~valid), 'kx', 'MarkerSize', 8, 'LineWidth', 1.2);
    grid on;
    ylim([-1.5 1.5]);
    yticks([-1 0 1]);
    xlabel('UI boundary');
    ylabel('phaseDecision');
    title('Digital BBPD decision: +1 early, -1 late, 0 invalid');
    legend('phaseDecision', 'valid', 'invalid', 'Location', 'best');

    saveas(fig, wavePng);
    close(fig);

    waveformResult = struct();
    waveformResult.Bits = bits;
    waveformResult.TransitionOffsetUI = transitionOffsetUI;
    waveformResult.DataSample = dataSample;
    waveformResult.EdgeSample = edgeSample;
    waveformResult.PhaseDecision = phaseDecision;
    waveformResult.Valid = valid;
    waveformResult.RawDecision = output.RawDecision;
    waveformResult.NumTransitions = sum(output.Transition);
    waveformResult.NumValid = sum(valid);
end

function assertThrowsId(fh, expectedId, message)
    try
        fh();
    catch err
        assert(strcmp(err.identifier, expectedId), ...
            '%s: expected %s, received %s', message, expectedId, err.identifier);
        return;
    end
    error('%s: function did not throw.', message);
end

function assertEqual(actual, expected, message)
    assert(isequaln(actual, expected), message);
end
