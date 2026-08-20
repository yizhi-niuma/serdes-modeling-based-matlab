function test_tx_channel
% test_tx_channel  Automated regression checks for tx_channel.

thisFile = mfilename('fullpath');
testDir = fileparts(thisFile);
repoRoot = fileparts(fileparts(testDir));
sourceDir = fullfile(repoRoot, 'src', 'TX+Channel');
afeDir = fullfile(repoRoot, 'src', 'AFE');
channelFile = fullfile(repoRoot, 'data', 'Channel', ...
    'DPO_4in_Meg7_THRU.s4p');
addpath(sourceDir);
addpath(afeDir);

model = tx_channel();

testDefaultConfiguration(model, channelFile);
testZeroOrderHold(model);
testChannelOutput(model);
testCtleConnection(model);
testInvalidInput(model, channelFile);

fprintf('test_tx_channel passed 5 / 5 checks.\n');
end

function testDefaultConfiguration(model, channelFile)
assert(strcmp(model.ChannelFile, channelFile));
assert(model.SymbolRate == 56e9);
assert(model.SamplesPerSymbol == 128);
assert(model.SampleRate == 56e9 * 128);
assert(abs(model.SampleInterval - 1 / model.SampleRate) < eps);
assert(iscolumn(model.ImpulseResponse));
assert(all(isfinite(model.ImpulseResponse)));
end

function testZeroOrderHold(model)
rowSymbols = [-3 -1 1 3];
rowWaveform = model.symbolsToWaveform(rowSymbols);
expectedRow = repelem(rowSymbols, model.SamplesPerSymbol);

columnSymbols = rowSymbols.';
columnWaveform = model.symbolsToWaveform(columnSymbols);

assert(isequal(rowWaveform, expectedRow));
assert(isequal(columnWaveform, expectedRow.'));
end

function testChannelOutput(model)
symbols = [zeros(1, 64), ones(1, 64)];
[outputWaveform, time] = model.process(symbols);

assert(isrow(outputWaveform));
assert(isequal(size(outputWaveform), size(time)));
assert(numel(outputWaveform) == numel(symbols) * model.SamplesPerSymbol);
assert(all(isfinite(outputWaveform)));
assert(time(1) == 0);
assert(abs(time(2) - time(1) - model.SampleInterval) < eps);
assert(any(abs(outputWaveform) > 0));

[columnOutput, columnTime] = model.process(symbols.');
assert(iscolumn(columnOutput));
assert(iscolumn(columnTime));
assert(isequal(columnOutput, outputWaveform.'));
end

function testCtleConnection(model)
symbols = repmat([-3 -1 1 3], 1, 32);
channelOutput = model.process(symbols);
ctleModel = ctle(model.SamplesPerSymbol);
ctleModel.SymbolRate = model.SymbolRate;
ctleOutput = ctleModel.process(channelOutput);

assert(isequal(size(ctleOutput), size(channelOutput)));
assert(all(isfinite(ctleOutput)));
end

function testInvalidInput(model, channelFile)
assertThrowsId(@() model.process([]), 'tx_channel:InvalidSymbols');
assertThrowsId(@() model.process([0 NaN]), 'tx_channel:InvalidSymbols');
assertThrowsId(@() model.process([0 1; 2 3]), 'tx_channel:InvalidSymbols');
assertThrowsId(@() tx_channel(channelFile, 0), ...
    'tx_channel:InvalidConfiguration');
assertThrowsId(@() tx_channel(channelFile, 56e9, 1.5), ...
    'tx_channel:InvalidConfiguration');
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
